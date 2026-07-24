#include "grpc_cache_protocol.hpp"

#include <chrono>
#include <cstring>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <string>

namespace {

uint64_t fnv1a_update(uint64_t hash, const uint8_t *data, size_t len)
{
    for (size_t i = 0; i < len; ++i) {
        hash ^= data[i];
        hash *= 1099511628211ull;
    }
    return hash;
}

void append_all(std::vector<uint8_t> *out, const std::vector<uint8_t> &data)
{
    out->insert(out->end(), data.begin(), data.end());
}

bool read_hpack_string(const std::vector<uint8_t> &block, size_t *offset,
                       std::string *out)
{
    if (*offset >= block.size())
        return false;

    uint8_t first = block[*offset];
    bool huffman = first & 0x80;
    size_t len = first & 0x7f;
    (*offset)++;

    if (huffman || *offset + len > block.size())
        return false;

    out->assign(reinterpret_cast<const char *>(block.data() + *offset), len);
    *offset += len;
    return true;
}

void parse_demo_headers(const std::vector<uint8_t> &block, RequestInfo *info)
{
    size_t offset = 0;
    while (offset < block.size()) {
        uint8_t first = block[offset++];

        if (first & 0x80)
            continue;

        if ((first & 0xf0) == 0x00) {
            std::string name;
            std::string value;
            if (!read_hpack_string(block, &offset, &name) ||
                !read_hpack_string(block, &offset, &value))
                return;
            if (name == ":path") {
                info->method = value;
                info->saw_headers = true;
            }
            continue;
        }

        return;
    }
}

void update_payload_hash(const std::vector<uint8_t> &payload, RequestInfo *info)
{
    if (payload.size() <= 5)
        return;

    info->payload_hash = fnv1a_update(info->payload_hash,
                                      payload.data() + 5,
                                      payload.size() - 5);
    info->saw_data = true;
}

void append_frame_header(std::vector<uint8_t> *out, uint32_t len, uint8_t type,
                         uint8_t flags, uint32_t stream_id)
{
    out->push_back(static_cast<uint8_t>((len >> 16) & 0xff));
    out->push_back(static_cast<uint8_t>((len >> 8) & 0xff));
    out->push_back(static_cast<uint8_t>(len & 0xff));
    out->push_back(type);
    out->push_back(flags);
    out->push_back(static_cast<uint8_t>((stream_id >> 24) & 0x7f));
    out->push_back(static_cast<uint8_t>((stream_id >> 16) & 0xff));
    out->push_back(static_cast<uint8_t>((stream_id >> 8) & 0xff));
    out->push_back(static_cast<uint8_t>(stream_id & 0xff));
}

void append_hpack_string(std::vector<uint8_t> *out, const std::string &value)
{
    out->push_back(static_cast<uint8_t>(value.size()));
    out->insert(out->end(), value.begin(), value.end());
}

void append_literal_header(std::vector<uint8_t> *out, const std::string &name,
                           const std::string &value)
{
    out->push_back(0x00);
    append_hpack_string(out, name);
    append_hpack_string(out, value);
}

std::vector<uint8_t> build_headers_block(bool trailers)
{
    std::vector<uint8_t> block;
    if (!trailers) {
        block.push_back(0x88); // HPACK static table index 8: :status 200.
        append_literal_header(&block, "content-type", "application/grpc");
    } else {
        append_literal_header(&block, "grpc-status", "0");
    }
    return block;
}

bool read_exact(int fd, uint8_t *buf, size_t len, std::vector<uint8_t> *copy)
{
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (n == 0)
            return false;
        size_t read_len = static_cast<size_t>(n);
        if (copy)
            copy->insert(copy->end(), buf + got, buf + got + read_len);
        got += read_len;
    }
    return true;
}

} // namespace

std::vector<uint8_t> build_grpc_health_response(uint32_t stream_id,
                                                HealthStatus status)
{
    std::vector<uint8_t> response;
    std::vector<uint8_t> headers = build_headers_block(false);
    append_frame_header(&response, headers.size(), 0x1, 0x4, stream_id);
    append_all(&response, headers);

    std::vector<uint8_t> grpc_data = {
        0x00, 0x00, 0x00, 0x00, 0x02,
        0x08,
        static_cast<uint8_t>(status)
    };
    append_frame_header(&response, grpc_data.size(), 0x0, 0x0, stream_id);
    append_all(&response, grpc_data);

    std::vector<uint8_t> trailers = build_headers_block(true);
    append_frame_header(&response, trailers.size(), 0x1, 0x5, stream_id);
    append_all(&response, trailers);
    return response;
}

bool send_all(int fd, const std::vector<uint8_t> &data)
{
    size_t sent = 0;
    while (sent < data.size()) {
        ssize_t n = send(fd, data.data() + sent, data.size() - sent,
                         MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        if (n == 0)
            return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool send_server_settings(int fd)
{
    std::vector<uint8_t> settings;
    append_frame_header(&settings, 0, 0x4, 0x0, 0);
    append_frame_header(&settings, 0, 0x4, 0x1, 0);
    return send_all(fd, settings);
}

bool read_request_stream(int fd, RequestInfo *info,
                         std::vector<uint8_t> *raw_request)
{
    const char expected_preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    uint8_t preface[24] = {};
    if (!read_exact(fd, preface, sizeof(preface), raw_request))
        return false;
    if (memcmp(preface, expected_preface, sizeof(preface)) != 0)
        return false;

    bool saw_stream = false;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (std::chrono::steady_clock::now() < deadline) {
        uint8_t hdr[9] = {};
        if (!read_exact(fd, hdr, sizeof(hdr), raw_request))
            return false;

        uint32_t len = (static_cast<uint32_t>(hdr[0]) << 16) |
                       (static_cast<uint32_t>(hdr[1]) << 8) |
                       static_cast<uint32_t>(hdr[2]);
        uint8_t type = hdr[3];
        uint8_t flags = hdr[4];
        uint32_t sid = ((static_cast<uint32_t>(hdr[5]) & 0x7f) << 24) |
                       (static_cast<uint32_t>(hdr[6]) << 16) |
                       (static_cast<uint32_t>(hdr[7]) << 8) |
                       static_cast<uint32_t>(hdr[8]);

        std::vector<uint8_t> payload(len);
        if (len > 0 && !read_exact(fd, payload.data(), payload.size(), raw_request))
            return false;

        if (type == 0x1 && sid != 0) {
            info->stream_id = sid;
            saw_stream = true;
            parse_demo_headers(payload, info);
        } else if (type == 0x0 && sid == info->stream_id) {
            update_payload_hash(payload, info);
        }
        if (saw_stream && sid == info->stream_id && (flags & 0x1))
            return true;
    }
    return saw_stream;
}
