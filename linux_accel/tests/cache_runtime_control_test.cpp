#include "cache_runtime_control.h"

#include <cstdlib>
#include <iostream>

namespace {

[[noreturn]] void fail(const char *message)
{
    std::cerr << "cache_runtime_control_test: " << message << "\n";
    std::exit(1);
}

void expect(bool condition, const char *message)
{
    if (!condition)
        fail(message);
}

} // namespace

int main()
{
    cache_runtime_control legacy = {};
    expect(cache_runtime_control_allows(nullptr, CACHE_RUNTIME_ROLE_SERVER),
           "missing map value should preserve legacy behavior");
    expect(cache_runtime_control_allows(&legacy, CACHE_RUNTIME_ROLE_CLIENT),
           "zero-initialized map should preserve legacy behavior");

    cache_runtime_control staged = {};
    staged.epoch = 7;
    staged.mode = CACHE_RUNTIME_DUAL;
    expect(!cache_runtime_control_allows(&staged, CACHE_RUNTIME_ROLE_SERVER),
           "staged server policy must fail closed");
    expect(!cache_runtime_control_allows(&staged, CACHE_RUNTIME_ROLE_CLIENT),
           "staged client policy must fail closed");

    cache_runtime_control committed = staged;
    committed.flags = CACHE_RUNTIME_COMMITTED;
    expect(cache_runtime_control_allows(&committed,
                                        CACHE_RUNTIME_ROLE_SERVER),
           "dual mode should enable server cache");
    expect(cache_runtime_control_allows(&committed,
                                        CACHE_RUNTIME_ROLE_CLIENT),
           "dual mode should enable client cache");

    committed.mode = CACHE_RUNTIME_SERVER;
    expect(cache_runtime_control_allows(&committed,
                                        CACHE_RUNTIME_ROLE_SERVER),
           "server mode should enable server cache");
    expect(!cache_runtime_control_allows(&committed,
                                         CACHE_RUNTIME_ROLE_CLIENT),
           "server mode should disable client cache");

    committed.mode = CACHE_RUNTIME_CLIENT;
    expect(!cache_runtime_control_allows(&committed,
                                         CACHE_RUNTIME_ROLE_SERVER),
           "client mode should disable server cache");
    expect(cache_runtime_control_allows(&committed,
                                        CACHE_RUNTIME_ROLE_CLIENT),
           "client mode should enable client cache");

    committed.mode = CACHE_RUNTIME_BYPASS;
    expect(!cache_runtime_control_allows(&committed,
                                         CACHE_RUNTIME_ROLE_SERVER),
           "bypass mode should disable server cache");
    expect(!cache_runtime_control_allows(&committed,
                                         CACHE_RUNTIME_ROLE_CLIENT),
           "bypass mode should disable client cache");

    std::cout << "cache_runtime_control_test: PASS\n";
    return 0;
}
