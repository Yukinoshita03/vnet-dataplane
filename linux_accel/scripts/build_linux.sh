#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

mkdir -p "${BUILD_DIR}"

command -v clang >/dev/null
command -v c++ >/dev/null
command -v python3 >/dev/null
command -v tc >/dev/null

MULTIARCH_INCLUDE="/usr/include/$(gcc -print-multiarch 2>/dev/null || true)"
BPF_INCLUDES=("-I${ROOT_DIR}/src/include" "-I${ROOT_DIR}/include")
if [[ -d "${MULTIARCH_INCLUDE}" ]]; then
  BPF_INCLUDES+=("-I${MULTIARCH_INCLUDE}")
fi

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/dns_monitor.c" \
  -o "${BUILD_DIR}/dns_monitor.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/dns_xdp_monitor.c" \
  -o "${BUILD_DIR}/dns_xdp_monitor.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/dns_client_cache.c" \
  -o "${BUILD_DIR}/dns_client_cache.bpf.o"

clang -target bpf -O2 -g \
  "${BPF_INCLUDES[@]}" \
  -c "${ROOT_DIR}/bpf/grpc_monitor.c" \
  -o "${BUILD_DIR}/grpc_monitor.bpf.o"

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/dns_cache_config.cpp" \
  "${ROOT_DIR}/src/dns_monitor.cpp" \
  "${ROOT_DIR}/src/dns_monitor_args.cpp" \
  "${ROOT_DIR}/src/dns_monitor_metrics.cpp" \
  -o "${BUILD_DIR}/dns_monitor" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/grpc_monitor.cpp" \
  -o "${BUILD_DIR}/grpc_monitor" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/grpc_fast_cache.cpp" \
  "${ROOT_DIR}/src/grpc_cache_protocol.cpp" \
  "${ROOT_DIR}/src/cache_policy.cpp" \
  "${ROOT_DIR}/src/dns_cache_config.cpp" \
  -o "${BUILD_DIR}/grpc_fast_cache" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/cachectl.cpp" \
  "${ROOT_DIR}/src/cache_policy.cpp" \
  "${ROOT_DIR}/src/dns_cache_config.cpp" \
  -o "${BUILD_DIR}/cachectl" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/packet_parser.cpp" \
  "${ROOT_DIR}/src/virt_service_classifier.cpp" \
  -o "${BUILD_DIR}/virt_service_classifier"

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  "${ROOT_DIR}/tests/tc_coexistence_test.cpp" \
  -o "${BUILD_DIR}/tc_coexistence_test"

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/dynamic_cache_controller_main.cpp" \
  "${ROOT_DIR}/src/dynamic_cache_controller.cpp" \
  "${ROOT_DIR}/src/bpf_cache_policy_publisher.cpp" \
  -o "${BUILD_DIR}/dynamic_cache_controller" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  -I"${ROOT_DIR}/include" \
  "${ROOT_DIR}/src/cache_policy_txn.cpp" \
  "${ROOT_DIR}/src/dynamic_cache_controller.cpp" \
  -o "${BUILD_DIR}/cache_policy_txn" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  "${ROOT_DIR}/src/dns_cache_stats_reader.cpp" \
  -o "${BUILD_DIR}/dns_cache_stats_reader" \
  -lbpf -lelf -lz

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  "${ROOT_DIR}/tests/dynamic_cache_controller_test.cpp" \
  "${ROOT_DIR}/src/dynamic_cache_controller.cpp" \
  -o "${BUILD_DIR}/dynamic_cache_controller_test"

c++ -std=c++17 -O2 -g \
  -I"${ROOT_DIR}/src/include" \
  "${ROOT_DIR}/tests/cache_runtime_control_test.cpp" \
  -o "${BUILD_DIR}/cache_runtime_control_test"

c++ -std=c++17 -O2 -g -Wall -Wextra -Werror \
  -I"${ROOT_DIR}/src/include" \
  "${ROOT_DIR}/tests/cache_policy_txn_path_test.cpp" \
  -o "${BUILD_DIR}/cache_policy_txn_path_test"

cc -O2 -g \
  "${ROOT_DIR}/bench/openstack_dns_harness.c" \
  -o "${BUILD_DIR}/openstack_dns_harness"

cc -O2 -g \
  "${ROOT_DIR}/bench/openstack_grpc_harness.c" \
  -o "${BUILD_DIR}/openstack_grpc_harness"

"${BUILD_DIR}/tc_coexistence_test"
"${BUILD_DIR}/dynamic_cache_controller_test"
bash "${ROOT_DIR}/tests/dynamic_cache_desired_mode_test.sh" \
  "${BUILD_DIR}/dynamic_cache_controller"
"${BUILD_DIR}/cache_runtime_control_test"
"${BUILD_DIR}/cache_policy_txn_path_test"
bash "${ROOT_DIR}/tests/openstack_dns_harness_domain_test.sh"
bash "${ROOT_DIR}/tests/grpc_fast_cache_metrics_test.sh"
bash "${ROOT_DIR}/tests/tc_pipeline_semantics_test.sh"
bash -n "${ROOT_DIR}/tests/hook_ownership_regression_test.sh"
bash -n "${ROOT_DIR}/tests/grpc_stream_correlation_test.sh"
bash -n "${ROOT_DIR}/tests/cache_policy_txn_integration_test.sh"
bash "${ROOT_DIR}/tests/openstack_campaign_lifecycle_test.sh"
bash "${ROOT_DIR}/tests/openstack_systemd_dynamic_e2e_lifecycle_test.sh"
python3 -m py_compile "${ROOT_DIR}/tests/grpc_h2_stream_replay.py"
(cd "${ROOT_DIR}" &&
  python3 -m unittest \
    tests.test_openstack_dataplane_agent \
    tests.test_openstack_epoch_gate \
    tests.test_openstack_epoch_coordinator \
    tests.test_openstack_guest_endpoint_agent \
    tests.test_openstack_metrics_bridge \
    tests.test_openstack_migration_leg \
    tests.test_migration_continuity_probe \
    tests.test_openstack_shared_cluster_preflight \
    tests.test_render_openstack_shared_bundle \
    tests.test_stage_openstack_shared_deployment \
    tests.test_monitor_initial_runtime_bypass)

echo "Built ${BUILD_DIR}/dns_monitor.bpf.o"
echo "Built ${BUILD_DIR}/dns_xdp_monitor.bpf.o"
echo "Built ${BUILD_DIR}/dns_client_cache.bpf.o"
echo "Built ${BUILD_DIR}/grpc_monitor.bpf.o"
echo "Built ${BUILD_DIR}/dns_monitor"
echo "Built ${BUILD_DIR}/grpc_monitor"
echo "Built ${BUILD_DIR}/grpc_fast_cache"
echo "Built ${BUILD_DIR}/cachectl"
echo "Built ${BUILD_DIR}/virt_service_classifier"
echo "Built ${BUILD_DIR}/dynamic_cache_controller"
echo "Built ${BUILD_DIR}/cache_policy_txn"
echo "Built ${BUILD_DIR}/dns_cache_stats_reader"
echo "Built ${BUILD_DIR}/openstack_dns_harness"
echo "Built ${BUILD_DIR}/openstack_grpc_harness"
echo "Passed ${BUILD_DIR}/tc_coexistence_test"
echo "Passed ${BUILD_DIR}/dynamic_cache_controller_test"
echo "Passed ${ROOT_DIR}/tests/dynamic_cache_desired_mode_test.sh"
echo "Passed ${BUILD_DIR}/cache_runtime_control_test"
echo "Passed ${BUILD_DIR}/cache_policy_txn_path_test"
echo "Passed ${ROOT_DIR}/tests/openstack_dns_harness_domain_test.sh"
echo "Passed ${ROOT_DIR}/tests/grpc_fast_cache_metrics_test.sh"
echo "Passed ${ROOT_DIR}/tests/tc_pipeline_semantics_test.sh"
echo "Checked ${ROOT_DIR}/tests/hook_ownership_regression_test.sh"
echo "Checked ${ROOT_DIR}/tests/grpc_stream_correlation_test.sh"
echo "Checked ${ROOT_DIR}/tests/cache_policy_txn_integration_test.sh"
echo "Passed ${ROOT_DIR}/tests/openstack_campaign_lifecycle_test.sh"
echo "Passed ${ROOT_DIR}/tests/openstack_systemd_dynamic_e2e_lifecycle_test.sh"
echo "Checked ${ROOT_DIR}/tests/grpc_h2_stream_replay.py"
echo "Passed ${ROOT_DIR}/tests/test_openstack_dataplane_agent.py"
echo "Passed ${ROOT_DIR}/tests/test_openstack_epoch_gate.py"
echo "Passed ${ROOT_DIR}/tests/test_openstack_epoch_coordinator.py"
echo "Passed ${ROOT_DIR}/tests/test_openstack_guest_endpoint_agent.py"
echo "Passed ${ROOT_DIR}/tests/test_openstack_metrics_bridge.py"
echo "Passed ${ROOT_DIR}/tests/test_openstack_migration_leg.py"
echo "Passed ${ROOT_DIR}/tests/test_migration_continuity_probe.py"
echo "Passed ${ROOT_DIR}/tests/test_openstack_shared_cluster_preflight.py"
echo "Passed ${ROOT_DIR}/tests/test_render_openstack_shared_bundle.py"
echo "Passed ${ROOT_DIR}/tests/test_stage_openstack_shared_deployment.py"
echo "Passed ${ROOT_DIR}/tests/test_monitor_initial_runtime_bypass.py"
