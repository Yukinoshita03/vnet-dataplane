#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "policy_model.hpp"

bool decode_policy_feed_message(const std::string &wire,
                                PolicyFeedEvent *event, std::string *error);
std::string encode_policy_feed_message(const PolicyFeedEvent &event,
                                       std::string *error);

class PolicyFeedServer {
public:
    static std::unique_ptr<PolicyFeedServer>
    Create(const std::string &socket_path, int allowed_uid, std::string *error);

    PolicyFeedServer(const PolicyFeedServer &) = delete;
    PolicyFeedServer &operator=(const PolicyFeedServer &) = delete;

    ~PolicyFeedServer();

    // Non-blocking. Returns the number of accepted policy events.
    int Poll(std::vector<PolicyFeedEvent> *events, std::string *error);

private:
    PolicyFeedServer(int listen_fd, std::string socket_path, int allowed_uid);

    bool accept_clients(std::string *error);

    int listen_fd_;
    std::string socket_path_;
    int allowed_uid_;
    std::vector<int> clients_;
};
