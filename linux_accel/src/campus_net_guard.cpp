#include <curl/curl.h>

#include <arpa/inet.h>
#include <ifaddrs.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <net/if.h>
#if defined(__APPLE__)
#include <net/if_dl.h>
#endif
#include <netinet/in.h>
#include <sys/stat.h>

namespace {

using Clock = std::chrono::steady_clock;

constexpr std::size_t kDefaultMaxResponseBytes = 1024 * 1024;
constexpr int kDefaultProbeTimeoutMs = 5000;
constexpr int kDefaultAuthTimeoutMs = 10000;
constexpr int kDefaultIntervalSeconds = 15;
constexpr int kDefaultOfflineThreshold = 2;
constexpr int kDefaultMinRetrySeconds = 10;
constexpr int kDefaultMaxRetrySeconds = 300;

volatile std::sig_atomic_t g_stop = 0;

void HandleSignal(int) {
  g_stop = 1;
}

std::string Trim(std::string value) {
  std::size_t begin = 0;
  while (begin < value.size() &&
         std::isspace(static_cast<unsigned char>(value[begin])) != 0) {
    ++begin;
  }

  std::size_t end = value.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(value[end - 1])) != 0) {
    --end;
  }
  return value.substr(begin, end - begin);
}

std::string Lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string Upper(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::toupper(c));
  });
  return value;
}

std::string StripOptionalQuotes(std::string value) {
  if (value.size() >= 2) {
    const char first = value.front();
    const char last = value.back();
    if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
      return value.substr(1, value.size() - 2);
    }
  }
  return value;
}

bool ParseBool(std::string value, bool* result) {
  value = Lower(Trim(std::move(value)));
  if (value == "1" || value == "true" || value == "yes" || value == "on") {
    *result = true;
    return true;
  }
  if (value == "0" || value == "false" || value == "no" || value == "off") {
    *result = false;
    return true;
  }
  return false;
}

template <typename T>
bool ParseInteger(std::string value, T* result) {
  try {
    value = Trim(std::move(value));
    std::size_t consumed = 0;
    const long long parsed = std::stoll(value, &consumed, 10);
    if (consumed != value.size()) {
      return false;
    }
    *result = static_cast<T>(parsed);
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

std::vector<int> ParseStatusCodes(const std::string& value) {
  std::vector<int> result;
  std::size_t start = 0;
  while (start <= value.size()) {
    const std::size_t comma = value.find(',', start);
    const std::string token = Trim(value.substr(start, comma - start));
    if (!token.empty()) {
      int code = 0;
      if (!ParseInteger(token, &code) || code < 100 || code > 599) {
        throw std::runtime_error("invalid HTTP status code: " + token);
      }
      result.push_back(code);
    }
    if (comma == std::string::npos) {
      break;
    }
    start = comma + 1;
  }
  if (result.empty()) {
    throw std::runtime_error("HTTP status code list cannot be empty");
  }
  return result;
}

bool ContainsStatus(const std::vector<int>& statuses, long status) {
  return std::find(statuses.begin(), statuses.end(), status) != statuses.end();
}

bool HasPrefix(std::string_view value, std::string_view prefix) {
  return value.size() >= prefix.size() && value.substr(0, prefix.size()) == prefix;
}

bool IsRegularFile(const std::filesystem::path& path) {
  std::error_code error;
  return std::filesystem::is_regular_file(path, error);
}

bool HasPrivatePermissions(const std::filesystem::path& path, std::string* error) {
#if defined(_WIN32)
  (void)path;
  (void)error;
  return true;
#else
  struct stat file_stat {};
  if (stat(path.c_str(), &file_stat) != 0) {
    *error = "stat(" + path.string() + "): " + std::strerror(errno);
    return false;
  }
  if ((file_stat.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
    *error = path.string() + " must not be readable or writable by group/other; run chmod 600";
    return false;
  }
  return true;
#endif
}

std::optional<std::string> ReadTextFile(const std::filesystem::path& path,
                                        std::size_t max_bytes,
                                        std::string* error) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    *error = "cannot open " + path.string() + ": " + std::strerror(errno);
    return std::nullopt;
  }

  std::string value;
  value.reserve(128);
  std::array<char, 512> buffer{};
  while (input) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize count = input.gcount();
    if (count > 0) {
      if (value.size() + static_cast<std::size_t>(count) > max_bytes) {
        *error = path.string() + " is too large";
        return std::nullopt;
      }
      value.append(buffer.data(), static_cast<std::size_t>(count));
    }
  }

  while (!value.empty() && (value.back() == '\n' || value.back() == '\r')) {
    value.pop_back();
  }
  return value;
}

std::string EnvironmentOrEmpty(const std::string& name) {
  if (name.empty()) {
    return {};
  }
  const char* value = std::getenv(name.c_str());
  return value == nullptr ? std::string{} : std::string(value);
}

void ReplaceAll(std::string* value, std::string_view needle, std::string_view replacement) {
  std::size_t position = 0;
  while ((position = value->find(needle, position)) != std::string::npos) {
    value->replace(position, needle.size(), replacement);
    position += replacement.size();
  }
}

std::string ExpandPlaceholders(std::string value,
                               const std::string& username,
                               const std::string& password,
                               const std::string& operator_name,
                               const std::string& local_ipv4,
                               const std::string& local_mac) {
  ReplaceAll(&value, "{username}", username);
  ReplaceAll(&value, "{password}", password);
  ReplaceAll(&value, "{operator}", operator_name);
  ReplaceAll(&value, "{local_ipv4}", local_ipv4);
  ReplaceAll(&value, "{local_mac}", local_mac);
  return value;
}

std::string PercentEncode(std::string_view value) {
  constexpr char kHex[] = "0123456789ABCDEF";
  std::string result;
  result.reserve(value.size());
  for (const unsigned char c : value) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
      result.push_back(static_cast<char>(c));
    } else {
      result.push_back('%');
      result.push_back(kHex[c >> 4]);
      result.push_back(kHex[c & 0x0f]);
    }
  }
  return result;
}

std::string JsonEscape(std::string_view value) {
  constexpr char kHex[] = "0123456789abcdef";
  std::string result;
  result.reserve(value.size() + 2);
  for (const unsigned char c : value) {
    switch (c) {
      case '"':
        result += "\\\"";
        break;
      case '\\':
        result += "\\\\";
        break;
      case '\b':
        result += "\\b";
        break;
      case '\f':
        result += "\\f";
        break;
      case '\n':
        result += "\\n";
        break;
      case '\r':
        result += "\\r";
        break;
      case '\t':
        result += "\\t";
        break;
      default:
        if (c < 0x20) {
          result += "\\u00";
          result.push_back(kHex[c >> 4]);
          result.push_back(kHex[c & 0x0f]);
        } else {
          result.push_back(static_cast<char>(c));
        }
        break;
    }
  }
  return result;
}

struct Config {
  std::string probe_url;
  std::string auth_url;
  std::string pre_auth_url;
  std::string username;
  std::string username_env = "CAMPUS_NET_USERNAME";
  std::string password;
  std::string password_env = "CAMPUS_NET_PASSWORD";
  std::filesystem::path password_file;
  std::string interface_name;
  std::string local_ipv4;
  std::string local_mac;
  std::string operator_name;
  std::string username_field = "username";
  std::string password_field = "password";
  std::string username_value = "{username}";
  std::string password_value = "{password}";
  std::string auth_method = "POST";
  std::string request_format = "form";
  std::string user_agent = "campus-net-guard/1.0";
  std::filesystem::path cookie_file;
  std::map<std::string, std::string> fields;
  std::map<std::string, std::string> headers;

  std::vector<int> probe_success_status = {200, 204};
  std::string probe_success_contains;
  std::vector<int> auth_success_status = {200, 204, 302};
  std::string auth_success_contains;
  std::string auth_failure_contains;

  int probe_timeout_ms = kDefaultProbeTimeoutMs;
  int auth_timeout_ms = kDefaultAuthTimeoutMs;
  int interval_seconds = kDefaultIntervalSeconds;
  int offline_threshold = kDefaultOfflineThreshold;
  int verify_delay_ms = 500;
  int min_retry_seconds = kDefaultMinRetrySeconds;
  int max_retry_seconds = kDefaultMaxRetrySeconds;
  std::size_t max_response_bytes = kDefaultMaxResponseBytes;
  bool follow_auth_redirects = true;
  bool tls_verify = true;
};

bool UsesPlaceholder(const Config& config, std::string_view placeholder) {
  if (config.username_value.find(placeholder) != std::string::npos ||
      config.password_value.find(placeholder) != std::string::npos) {
    return true;
  }
  for (const auto& [name, value] : config.fields) {
    (void)name;
    if (value.find(placeholder) != std::string::npos) {
      return true;
    }
  }
  return false;
}

std::optional<std::string> DiscoverLocalIPv4(const std::string& interface_name,
                                             std::string* error) {
  struct ifaddrs* addresses = nullptr;
  if (getifaddrs(&addresses) != 0) {
    *error = "getifaddrs failed: " + std::string(std::strerror(errno));
    return std::nullopt;
  }

  std::optional<std::string> result;
  for (const ifaddrs* address = addresses; address != nullptr; address = address->ifa_next) {
    if (address->ifa_addr == nullptr || address->ifa_addr->sa_family != AF_INET ||
        address->ifa_name == nullptr) {
      continue;
    }
    if (!interface_name.empty() && interface_name != address->ifa_name) {
      continue;
    }
    if (interface_name.empty() && (address->ifa_flags & IFF_LOOPBACK) != 0) {
      continue;
    }

    char buffer[INET_ADDRSTRLEN] = {};
    const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(address->ifa_addr);
    if (inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer)) != nullptr) {
      result = buffer;
      break;
    }
  }
  freeifaddrs(addresses);

  if (!result.has_value()) {
    *error = interface_name.empty() ? "no non-loopback IPv4 address found"
                                    : "no IPv4 address found on interface " + interface_name;
  }
  return result;
}

std::optional<std::string> DiscoverLocalMac(const std::string& interface_name,
                                            std::string* error) {
  if (interface_name.empty()) {
    *error = "interface is required to discover local_mac; set local_mac explicitly otherwise";
    return std::nullopt;
  }
#if defined(__linux__)
  const std::filesystem::path address_path =
      std::filesystem::path("/sys/class/net") / interface_name / "address";
  const std::optional<std::string> address = ReadTextFile(address_path, 64, error);
  if (!address.has_value()) {
    return std::nullopt;
  }
  std::string compact;
  compact.reserve(address->size());
  for (const char c : *address) {
    if (c != ':') {
      compact.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
    }
  }
  if (compact.empty()) {
    *error = "empty MAC address for interface " + interface_name;
    return std::nullopt;
  }
  return compact;
#else
#if defined(__APPLE__)
  struct ifaddrs* addresses = nullptr;
  if (getifaddrs(&addresses) != 0) {
    *error = "getifaddrs failed: " + std::string(std::strerror(errno));
    return std::nullopt;
  }

  std::optional<std::string> result;
  constexpr char kHex[] = "0123456789abcdef";
  for (const ifaddrs* address = addresses; address != nullptr; address = address->ifa_next) {
    if (address->ifa_addr == nullptr || address->ifa_name == nullptr ||
        interface_name != address->ifa_name || address->ifa_addr->sa_family != AF_LINK) {
      continue;
    }
    const auto* link = reinterpret_cast<const sockaddr_dl*>(address->ifa_addr);
    if (link->sdl_alen < 6) {
      continue;
    }
    const auto* mac = reinterpret_cast<const unsigned char*>(LLADDR(link));
    std::string compact;
    compact.reserve(12);
    for (int index = 0; index < 6; ++index) {
      compact.push_back(kHex[(mac[index] >> 4) & 0x0f]);
      compact.push_back(kHex[mac[index] & 0x0f]);
    }
    result = compact;
    break;
  }
  freeifaddrs(addresses);

  if (!result.has_value()) {
    *error = "no MAC address found on interface " + interface_name;
  }
  return result;
#else
  *error = "automatic local_mac discovery is implemented for Linux and macOS; set local_mac explicitly";
  return std::nullopt;
#endif
#endif
}

bool AssignConfigValue(Config* config,
                       const std::string& key,
                       const std::string& raw_value,
                       std::string* error) {
  const std::string value = StripOptionalQuotes(Trim(raw_value));

  if (HasPrefix(key, "field.")) {
    const std::string field_name = key.substr(std::string("field.").size());
    if (field_name.empty()) {
      *error = "field name cannot be empty";
      return false;
    }
    config->fields[field_name] = value;
    return true;
  }
  if (HasPrefix(key, "header.")) {
    const std::string header_name = key.substr(std::string("header.").size());
    if (header_name.empty()) {
      *error = "header name cannot be empty";
      return false;
    }
    config->headers[header_name] = value;
    return true;
  }

  if (key == "probe_url") {
    config->probe_url = value;
  } else if (key == "auth_url") {
    config->auth_url = value;
  } else if (key == "pre_auth_url") {
    config->pre_auth_url = value;
  } else if (key == "username") {
    config->username = value;
  } else if (key == "username_env") {
    config->username_env = value;
  } else if (key == "password") {
    config->password = value;
  } else if (key == "password_env") {
    config->password_env = value;
  } else if (key == "password_file") {
    config->password_file = value;
  } else if (key == "interface") {
    config->interface_name = value;
  } else if (key == "local_ipv4") {
    config->local_ipv4 = value;
  } else if (key == "local_mac") {
    config->local_mac = value;
  } else if (key == "operator") {
    config->operator_name = value;
  } else if (key == "username_field") {
    config->username_field = value;
  } else if (key == "password_field") {
    config->password_field = value;
  } else if (key == "username_value") {
    config->username_value = value;
  } else if (key == "password_value") {
    config->password_value = value;
  } else if (key == "auth_method") {
    config->auth_method = Upper(value);
  } else if (key == "request_format") {
    config->request_format = Lower(value);
  } else if (key == "user_agent") {
    config->user_agent = value;
  } else if (key == "cookie_file") {
    config->cookie_file = value;
  } else if (key == "probe_success_status") {
    try {
      config->probe_success_status = ParseStatusCodes(value);
    } catch (const std::exception& exception) {
      *error = exception.what();
      return false;
    }
  } else if (key == "probe_success_contains") {
    config->probe_success_contains = value;
  } else if (key == "auth_success_status") {
    try {
      config->auth_success_status = ParseStatusCodes(value);
    } catch (const std::exception& exception) {
      *error = exception.what();
      return false;
    }
  } else if (key == "auth_success_contains") {
    config->auth_success_contains = value;
  } else if (key == "auth_failure_contains") {
    config->auth_failure_contains = value;
  } else if (key == "probe_timeout_ms") {
    if (!ParseInteger(value, &config->probe_timeout_ms)) {
      *error = "invalid probe_timeout_ms";
      return false;
    }
  } else if (key == "auth_timeout_ms") {
    if (!ParseInteger(value, &config->auth_timeout_ms)) {
      *error = "invalid auth_timeout_ms";
      return false;
    }
  } else if (key == "interval_seconds") {
    if (!ParseInteger(value, &config->interval_seconds)) {
      *error = "invalid interval_seconds";
      return false;
    }
  } else if (key == "offline_threshold") {
    if (!ParseInteger(value, &config->offline_threshold)) {
      *error = "invalid offline_threshold";
      return false;
    }
  } else if (key == "verify_delay_ms") {
    if (!ParseInteger(value, &config->verify_delay_ms)) {
      *error = "invalid verify_delay_ms";
      return false;
    }
  } else if (key == "min_retry_seconds") {
    if (!ParseInteger(value, &config->min_retry_seconds)) {
      *error = "invalid min_retry_seconds";
      return false;
    }
  } else if (key == "max_retry_seconds") {
    if (!ParseInteger(value, &config->max_retry_seconds)) {
      *error = "invalid max_retry_seconds";
      return false;
    }
  } else if (key == "max_response_bytes") {
    long long parsed = 0;
    if (!ParseInteger(value, &parsed) || parsed <= 0) {
      *error = "invalid max_response_bytes";
      return false;
    }
    config->max_response_bytes = static_cast<std::size_t>(parsed);
  } else if (key == "follow_auth_redirects") {
    if (!ParseBool(value, &config->follow_auth_redirects)) {
      *error = "invalid follow_auth_redirects";
      return false;
    }
  } else if (key == "tls_verify") {
    if (!ParseBool(value, &config->tls_verify)) {
      *error = "invalid tls_verify";
      return false;
    }
  } else {
    std::cerr << "warning: ignoring unknown config key: " << key << '\n';
  }
  return true;
}

bool LoadConfig(const std::filesystem::path& path, Config* config, std::string* error) {
  if (!IsRegularFile(path)) {
    *error = "config file not found: " + path.string();
    return false;
  }

  if (!HasPrivatePermissions(path, error)) {
    return false;
  }

  std::ifstream input(path);
  if (!input) {
    *error = "cannot open config file: " + path.string();
    return false;
  }

  std::string line;
  std::size_t line_number = 0;
  while (std::getline(input, line)) {
    ++line_number;
    line = Trim(std::move(line));
    if (line.empty() || line.front() == '#' || line.front() == ';') {
      continue;
    }

    const std::size_t separator = line.find('=');
    if (separator == std::string::npos) {
      *error = path.string() + ":" + std::to_string(line_number) +
               ": expected key=value";
      return false;
    }
    const std::string key = Trim(line.substr(0, separator));
    if (key.empty()) {
      *error = path.string() + ":" + std::to_string(line_number) + ": empty key";
      return false;
    }
    if (!AssignConfigValue(config, key, line.substr(separator + 1), error)) {
      *error = path.string() + ":" + std::to_string(line_number) + ": " + *error;
      return false;
    }
  }
  return true;
}

bool ResolveCredentials(Config* config, std::string* error) {
  if (config->username.empty()) {
    config->username = EnvironmentOrEmpty(config->username_env);
  }
  if (config->username.empty()) {
    *error = "username is missing; set username or " + config->username_env;
    return false;
  }

  const bool had_inline_password = !config->password.empty();
  if (!config->password_file.empty()) {
    if (!IsRegularFile(config->password_file)) {
      *error = "password file not found: " + config->password_file.string();
      return false;
    }
    if (!HasPrivatePermissions(config->password_file, error)) {
      return false;
    }
    const std::optional<std::string> password =
        ReadTextFile(config->password_file, 4096, error);
    if (!password.has_value()) {
      return false;
    }
    config->password = *password;
  } else if (config->password.empty()) {
    config->password = EnvironmentOrEmpty(config->password_env);
  }

  if (config->password.empty()) {
    *error = "password is missing; set password_file, password, or " + config->password_env;
    return false;
  }
  if (!config->password_file.empty() && had_inline_password) {
    // The password file wins, but this warning also makes accidental duplicate
    // configuration visible without ever printing either secret.
    std::cerr << "warning: password_file is authoritative; inline password is ignored\n";
  }
  return true;
}

bool ResolveNetworkIdentity(Config* config, std::string* error) {
  if (UsesPlaceholder(*config, "{operator}") && config->operator_name.empty()) {
    *error = "operator is required when a field uses {operator}";
    return false;
  }

  if (UsesPlaceholder(*config, "{local_ipv4}")) {
    if (config->local_ipv4.empty()) {
      const std::optional<std::string> discovered =
          DiscoverLocalIPv4(config->interface_name, error);
      if (!discovered.has_value()) {
        return false;
      }
      config->local_ipv4 = *discovered;
    }
    in_addr parsed_address {};
    if (inet_pton(AF_INET, config->local_ipv4.c_str(), &parsed_address) != 1) {
      *error = "local_ipv4 is not a valid IPv4 address: " + config->local_ipv4;
      return false;
    }
  }

  if (UsesPlaceholder(*config, "{local_mac}") && config->local_mac.empty()) {
    const std::optional<std::string> discovered =
        DiscoverLocalMac(config->interface_name, error);
    if (!discovered.has_value()) {
      return false;
    }
    config->local_mac = *discovered;
  }
  return true;
}

bool ValidateConfig(const Config& config, std::string* error) {
  if (config.probe_url.empty()) {
    *error = "probe_url is required";
    return false;
  }
  if (config.auth_url.empty()) {
    *error = "auth_url is required";
    return false;
  }
  if (config.username_field.empty() || config.password_field.empty()) {
    *error = "username_field and password_field cannot be empty";
    return false;
  }
  if (config.auth_method != "GET" && config.auth_method != "POST") {
    *error = "auth_method must be GET or POST";
    return false;
  }
  if (config.request_format != "form" && config.request_format != "json") {
    *error = "request_format must be form or json";
    return false;
  }
  if (config.auth_method == "GET") {
    std::cerr << "warning: GET authentication puts the password in the URL; use POST when possible\n";
  }
  if (HasPrefix(config.auth_url, "http://")) {
    std::cerr << "warning: auth_url uses HTTP; credentials are not encrypted in transit\n";
  }
  if (config.probe_timeout_ms <= 0 || config.auth_timeout_ms <= 0 ||
      config.interval_seconds <= 0 || config.offline_threshold <= 0 ||
      config.verify_delay_ms < 0 || config.min_retry_seconds <= 0 ||
      config.max_retry_seconds < config.min_retry_seconds || config.max_response_bytes == 0) {
    *error = "timeout, interval, threshold, retry, and response settings are invalid";
    return false;
  }
  return true;
}

struct HttpResponse {
  CURLcode curl_code = CURLE_OK;
  long status = 0;
  std::string body;
  std::string error;
  bool body_limit_exceeded = false;
};

struct Request {
  std::string url;
  std::string method = "GET";
  std::string body;
  std::vector<std::string> headers;
  int timeout_ms = kDefaultProbeTimeoutMs;
  bool follow_redirects = false;
};

struct ResponseBuffer {
  std::string body;
  std::size_t max_bytes = kDefaultMaxResponseBytes;
  bool limit_exceeded = false;
};

std::size_t WriteResponse(char* data, std::size_t size, std::size_t count, void* opaque) {
  auto* buffer = static_cast<ResponseBuffer*>(opaque);
  const std::size_t bytes = size * count;
  if (bytes > buffer->max_bytes - std::min(buffer->max_bytes, buffer->body.size())) {
    buffer->limit_exceeded = true;
    return 0;
  }
  buffer->body.append(data, bytes);
  return bytes;
}

class CurlGlobal {
 public:
  CurlGlobal() {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) {
      throw std::runtime_error("curl_global_init failed");
    }
  }

  ~CurlGlobal() { curl_global_cleanup(); }
};

class HttpClient {
 public:
  explicit HttpClient(const Config& config) : config_(config) {
    if (!config_.cookie_file.empty()) {
      const std::filesystem::path parent = config_.cookie_file.parent_path();
      if (!parent.empty()) {
        std::error_code error;
        std::filesystem::create_directories(parent, error);
        if (error) {
          throw std::runtime_error("cannot create cookie directory " + parent.string() + ": " +
                                   error.message());
        }
      }
      if (!std::filesystem::exists(config_.cookie_file)) {
        std::ofstream cookie(config_.cookie_file, std::ios::app);
        if (!cookie) {
          throw std::runtime_error("cannot create cookie file: " + config_.cookie_file.string());
        }
      }
#if !defined(_WIN32)
      if (chmod(config_.cookie_file.c_str(), S_IRUSR | S_IWUSR) != 0) {
        throw std::runtime_error("chmod cookie file failed: " + config_.cookie_file.string() +
                                 ": " + std::strerror(errno));
      }
#endif
    }
  }

  HttpResponse Perform(const Request& request) const {
    HttpResponse response;
    CURL* curl = curl_easy_init();
    if (curl == nullptr) {
      response.curl_code = CURLE_FAILED_INIT;
      response.error = "curl_easy_init failed";
      return response;
    }

    ResponseBuffer body;
    body.max_bytes = config_.max_response_bytes;
    char error_buffer[CURL_ERROR_SIZE] = {};
    curl_slist* header_list = nullptr;
    for (const std::string& header : request.headers) {
      header_list = curl_slist_append(header_list, header.c_str());
    }

    curl_easy_setopt(curl, CURLOPT_URL, request.url.c_str());
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, request.method.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteResponse);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, error_buffer);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, static_cast<long>(request.timeout_ms));
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, static_cast<long>(request.timeout_ms));
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, request.follow_redirects ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, config_.user_agent.c_str());
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, config_.tls_verify ? 1L : 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, config_.tls_verify ? 2L : 0L);
    if (header_list != nullptr) {
      curl_easy_setopt(curl, CURLOPT_HTTPHEADER, header_list);
    }
    if (!config_.cookie_file.empty()) {
      curl_easy_setopt(curl, CURLOPT_COOKIEFILE, config_.cookie_file.c_str());
      curl_easy_setopt(curl, CURLOPT_COOKIEJAR, config_.cookie_file.c_str());
    }
    if (request.method == "POST") {
      curl_easy_setopt(curl, CURLOPT_POST, 1L);
      curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request.body.data());
      curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(request.body.size()));
    } else if (request.method == "GET") {
      curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    }

    response.curl_code = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response.status);
    response.body = std::move(body.body);
    response.body_limit_exceeded = body.limit_exceeded;
    if (response.curl_code != CURLE_OK) {
      if (body.limit_exceeded) {
        response.error = "response exceeded max_response_bytes";
      } else if (error_buffer[0] != '\0') {
        response.error = error_buffer;
      } else {
        response.error = curl_easy_strerror(response.curl_code);
      }
    }

    curl_slist_free_all(header_list);
    curl_easy_cleanup(curl);
    return response;
  }

 private:
  const Config& config_;
};

std::string UrlWithQuery(std::string url, const std::vector<std::pair<std::string, std::string>>& values) {
  if (values.empty()) {
    return url;
  }
  url += url.find('?') == std::string::npos ? '?' : '&';
  for (std::size_t index = 0; index < values.size(); ++index) {
    if (index != 0) {
      url.push_back('&');
    }
    url += PercentEncode(values[index].first);
    url.push_back('=');
    url += PercentEncode(values[index].second);
  }
  return url;
}

bool HeaderNameEquals(std::string_view header, std::string_view name) {
  const std::size_t separator = header.find(':');
  if (separator == std::string_view::npos) {
    return false;
  }
  return Lower(Trim(std::string(header.substr(0, separator)))) == Lower(std::string(name));
}

std::vector<std::string> BuildHeaders(const Config& config,
                                      std::string_view content_type) {
  std::vector<std::string> result;
  result.reserve(config.headers.size() + 2);
  bool has_content_type = false;
  for (const auto& [name, value] : config.headers) {
    const std::string header = name + ": " + value;
    has_content_type = has_content_type || HeaderNameEquals(header, "Content-Type");
    result.push_back(header);
  }
  if (!has_content_type && !content_type.empty()) {
    result.emplace_back("Content-Type: ");
    result.back() += content_type;
  }
  return result;
}

std::map<std::string, std::string> AuthFields(const Config& config) {
  std::map<std::string, std::string> fields;
  for (const auto& [name, value] : config.fields) {
    fields[name] = ExpandPlaceholders(value, config.username, config.password,
                                      config.operator_name, config.local_ipv4,
                                      config.local_mac);
  }
  fields[config.username_field] = ExpandPlaceholders(
      config.username_value, config.username, config.password, config.operator_name,
      config.local_ipv4, config.local_mac);
  fields[config.password_field] = ExpandPlaceholders(
      config.password_value, config.username, config.password, config.operator_name,
      config.local_ipv4, config.local_mac);
  return fields;
}

Request BuildAuthRequest(const Config& config) {
  const std::map<std::string, std::string> fields = AuthFields(config);
  std::vector<std::pair<std::string, std::string>> values;
  values.reserve(fields.size());
  for (const auto& entry : fields) {
    values.push_back(entry);
  }

  Request request;
  request.method = config.auth_method;
  request.timeout_ms = config.auth_timeout_ms;
  request.follow_redirects = config.follow_auth_redirects;

  if (config.auth_method == "GET") {
    request.url = UrlWithQuery(config.auth_url, values);
    request.headers = BuildHeaders(config, "");
    return request;
  }

  request.url = config.auth_url;
  if (config.request_format == "json") {
    std::ostringstream body;
    body << '{';
    for (std::size_t index = 0; index < values.size(); ++index) {
      if (index != 0) {
        body << ',';
      }
      body << '"' << JsonEscape(values[index].first) << "\":\""
           << JsonEscape(values[index].second) << '"';
    }
    body << '}';
    request.body = body.str();
    request.headers = BuildHeaders(config, "application/json");
  } else {
    std::ostringstream body;
    for (std::size_t index = 0; index < values.size(); ++index) {
      if (index != 0) {
        body << '&';
      }
      body << PercentEncode(values[index].first) << '=' << PercentEncode(values[index].second);
    }
    request.body = body.str();
    request.headers = BuildHeaders(config, "application/x-www-form-urlencoded");
  }
  return request;
}

Request BuildProbeRequest(const Config& config) {
  Request request;
  request.url = config.probe_url;
  request.method = "GET";
  request.timeout_ms = config.probe_timeout_ms;
  request.follow_redirects = false;
  request.headers = BuildHeaders(config, "");
  return request;
}

bool ResponseMatches(const HttpResponse& response,
                     const std::vector<int>& statuses,
                     const std::string& required_body,
                     const std::string& forbidden_body) {
  if (response.curl_code != CURLE_OK || response.body_limit_exceeded ||
      !ContainsStatus(statuses, response.status)) {
    return false;
  }
  if (!required_body.empty() && response.body.find(required_body) == std::string::npos) {
    return false;
  }
  if (!forbidden_body.empty() && response.body.find(forbidden_body) != std::string::npos) {
    return false;
  }
  return true;
}

std::string DescribeResponse(const HttpResponse& response) {
  if (response.curl_code != CURLE_OK) {
    return response.error.empty() ? curl_easy_strerror(response.curl_code) : response.error;
  }
  return "HTTP " + std::to_string(response.status) +
         ", response_bytes=" + std::to_string(response.body.size());
}

void WaitInterruptibly(std::chrono::seconds duration) {
  for (std::chrono::seconds elapsed{0}; elapsed < duration && g_stop == 0;
       elapsed += std::chrono::seconds(1)) {
    std::this_thread::sleep_for(std::chrono::seconds(1));
  }
}

void WaitInterruptibly(std::chrono::milliseconds duration) {
  constexpr auto kSlice = std::chrono::milliseconds(100);
  for (std::chrono::milliseconds elapsed{0}; elapsed < duration && g_stop == 0;
       elapsed += kSlice) {
    std::this_thread::sleep_for(std::min(kSlice, duration - elapsed));
  }
}

bool ProbeOnline(const HttpClient& client, const Config& config, HttpResponse* response) {
  *response = client.Perform(BuildProbeRequest(config));
  return ResponseMatches(*response, config.probe_success_status, config.probe_success_contains, {});
}

bool Authenticate(const HttpClient& client, const Config& config) {
  if (!config.pre_auth_url.empty()) {
    Request pre_auth;
    pre_auth.url = config.pre_auth_url;
    pre_auth.method = "GET";
    pre_auth.timeout_ms = config.auth_timeout_ms;
    pre_auth.follow_redirects = config.follow_auth_redirects;
    pre_auth.headers = BuildHeaders(config, "");
    const HttpResponse pre_auth_response = client.Perform(pre_auth);
    if (pre_auth_response.curl_code != CURLE_OK) {
      std::cerr << "[auth] pre-auth request failed: " << DescribeResponse(pre_auth_response)
                << '\n';
      return false;
    }
  }

  const HttpResponse response = client.Perform(BuildAuthRequest(config));
  const bool success = ResponseMatches(response, config.auth_success_status,
                                       config.auth_success_contains,
                                       config.auth_failure_contains);
  if (success) {
    std::cerr << "[auth] request accepted (" << DescribeResponse(response) << ")\n";
  } else {
    std::cerr << "[auth] request rejected (" << DescribeResponse(response) << ")\n";
  }
  return success;
}

int RunOnce(const Config& config, const HttpClient& client, bool dry_run) {
  HttpResponse response;
  if (ProbeOnline(client, config, &response)) {
    std::cerr << "[probe] online (" << DescribeResponse(response) << ")\n";
    return 0;
  }

  std::cerr << "[probe] offline or captive (" << DescribeResponse(response) << ")\n";
  if (dry_run) {
    std::cerr << "[auth] dry-run enabled; no credentials sent\n";
    return 1;
  }
  if (!Authenticate(client, config)) {
    return 1;
  }

  if (config.verify_delay_ms > 0) {
    WaitInterruptibly(std::chrono::milliseconds(config.verify_delay_ms));
  }
  if (ProbeOnline(client, config, &response)) {
    std::cerr << "[probe] network restored (" << DescribeResponse(response) << ")\n";
    return 0;
  }
  std::cerr << "[probe] authentication response accepted, but network is still unavailable ("
            << DescribeResponse(response) << ")\n";
  return 1;
}

int RunLoop(const Config& config, const HttpClient& client, bool dry_run) {
  int consecutive_offline = 0;
  int retry_seconds = 0;
  Clock::time_point next_auth = Clock::now();
  bool previous_online = false;
  bool have_previous_state = false;

  std::cerr << "campus_net_guard started; probe_interval=" << config.interval_seconds
            << "s, offline_threshold=" << config.offline_threshold << '\n';

  while (g_stop == 0) {
    HttpResponse response;
    const bool online = ProbeOnline(client, config, &response);
    if (online) {
      if (!have_previous_state || !previous_online) {
        std::cerr << "[probe] online (" << DescribeResponse(response) << ")\n";
      }
      consecutive_offline = 0;
      retry_seconds = 0;
      next_auth = Clock::now();
      previous_online = true;
      have_previous_state = true;
      WaitInterruptibly(std::chrono::seconds(config.interval_seconds));
      continue;
    }

    ++consecutive_offline;
    if (!have_previous_state || previous_online) {
      std::cerr << "[probe] offline or captive (" << DescribeResponse(response) << ")\n";
    }
    previous_online = false;
    have_previous_state = true;

    const bool threshold_reached = consecutive_offline >= config.offline_threshold;
    if (threshold_reached && Clock::now() >= next_auth) {
      if (dry_run) {
        std::cerr << "[auth] dry-run enabled; credentials will not be sent\n";
        next_auth = Clock::now() + std::chrono::seconds(config.max_retry_seconds);
      } else if (Authenticate(client, config)) {
        if (config.verify_delay_ms > 0) {
          WaitInterruptibly(std::chrono::milliseconds(config.verify_delay_ms));
        }
        if (ProbeOnline(client, config, &response)) {
          std::cerr << "[probe] network restored after authentication ("
                    << DescribeResponse(response) << ")\n";
          consecutive_offline = 0;
          retry_seconds = 0;
          next_auth = Clock::now();
          previous_online = true;
        } else {
          std::cerr << "[probe] authentication accepted, but verification is still offline ("
                    << DescribeResponse(response) << ")\n";
        }
      }

      if (!previous_online) {
        retry_seconds = retry_seconds == 0
                            ? config.min_retry_seconds
                            : std::min(config.max_retry_seconds, retry_seconds * 2);
        next_auth = Clock::now() + std::chrono::seconds(retry_seconds);
        std::cerr << "[auth] next attempt in " << retry_seconds << "s\n";
      }
    }

    WaitInterruptibly(std::chrono::seconds(config.interval_seconds));
  }

  std::cerr << "campus_net_guard stopped\n";
  return 0;
}

struct CommandLine {
  std::filesystem::path config_path = "/etc/campus-net-guard/config.conf";
  bool once = false;
  bool dry_run = false;
};

void PrintUsage(std::ostream& output) {
  output << "Usage: campus_net_guard [options]\n\n"
         << "Options:\n"
         << "  --config PATH   Read a private key=value config file\n"
         << "  --once          Probe once, authenticate if needed, then exit\n"
         << "  --dry-run       Never send the authentication request\n"
         << "  --help          Show this help\n\n"
         << "Credentials are read from password_file or the configured environment variables.\n";
}

bool ParseCommandLine(int argc, char** argv, CommandLine* command_line, std::string* error) {
  for (int index = 1; index < argc; ++index) {
    const std::string_view argument = argv[index];
    if (argument == "--help" || argument == "-h") {
      PrintUsage(std::cout);
      std::exit(0);
    }
    if (argument == "--once") {
      command_line->once = true;
      continue;
    }
    if (argument == "--dry-run") {
      command_line->dry_run = true;
      continue;
    }
    if (argument == "--config") {
      if (index + 1 >= argc) {
        *error = "--config requires a path";
        return false;
      }
      command_line->config_path = argv[++index];
      continue;
    }
    if (HasPrefix(argument, "--config=")) {
      command_line->config_path = std::string(argument.substr(std::string_view("--config=").size()));
      continue;
    }
    *error = "unknown argument: " + std::string(argument);
    return false;
  }
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  CommandLine command_line;
  std::string error;
  if (!ParseCommandLine(argc, argv, &command_line, &error)) {
    std::cerr << "error: " << error << '\n';
    PrintUsage(std::cerr);
    return 2;
  }

  Config config;
  if (!LoadConfig(command_line.config_path, &config, &error)) {
    std::cerr << "error: " << error << '\n';
    return 2;
  }
  if (!command_line.dry_run && !ResolveCredentials(&config, &error)) {
    std::cerr << "error: " << error << '\n';
    return 2;
  }
  if (!command_line.dry_run && !ResolveNetworkIdentity(&config, &error)) {
    std::cerr << "error: " << error << '\n';
    return 2;
  }
  if (!ValidateConfig(config, &error)) {
    std::cerr << "error: " << error << '\n';
    return 2;
  }

  std::signal(SIGINT, HandleSignal);
  std::signal(SIGTERM, HandleSignal);

  try {
    CurlGlobal curl_global;
    HttpClient client(config);
    if (command_line.once) {
      return RunOnce(config, client, command_line.dry_run);
    }
    return RunLoop(config, client, command_line.dry_run);
  } catch (const std::exception& exception) {
    std::cerr << "error: " << exception.what() << '\n';
    return 2;
  }
}
