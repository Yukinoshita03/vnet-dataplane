#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/grpc-h2c-monitor-bench/$(date +%Y%m%d-%H%M%S)}"
netns="${NETNS:-grpch2cbench}"
srv_if="${SRV_IF:-veth_h2c_srv}"
cli_if="${CLI_IF:-veth_h2c_cli}"
srv_ip="${SRV_IP:-10.30.0.1}"
cli_ip="${CLI_IP:-10.30.0.2}"
port="${PORT:-50051}"
requests="${REQUESTS:-1000}"
warmup="${WARMUP:-50}"
duration="${DURATION:-8}"
sudo_pass="${SUDO_PASS:-}"
go_work="${GO_WORK:-/tmp/grpc_h2c_demo}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

run_sudo() {
  if [[ -n "${sudo_pass}" ]]; then
    printf '%s\n' "${sudo_pass}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

cleanup() {
  run_sudo pkill -TERM -f "grpc-h2c-demo server" >/dev/null 2>&1 || true
  run_sudo pkill -TERM -f "grpc_monitor --dev ${srv_if}" >/dev/null 2>&1 || true
  run_sudo ip netns del "${netns}" >/dev/null 2>&1 || true
  run_sudo ip link del "${srv_if}" >/dev/null 2>&1 || true
}

write_go_demo() {
  rm -rf "${go_work}"
  mkdir -p "${go_work}"
  cat > "${go_work}/go.mod" <<'EOF'
module grpc-h2c-demo

go 1.22

require google.golang.org/grpc v1.64.1
EOF

  cat > "${go_work}/main.go" <<'EOF'
package main

import (
    "context"
    "flag"
    "fmt"
    "log"
    "net"
    "os"
    "sort"
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
    healthgrpc "google.golang.org/grpc/health/grpc_health_v1"
)

type healthServer struct {
    healthgrpc.UnimplementedHealthServer
}

func (healthServer) Check(context.Context, *healthgrpc.HealthCheckRequest) (*healthgrpc.HealthCheckResponse, error) {
    return &healthgrpc.HealthCheckResponse{Status: healthgrpc.HealthCheckResponse_SERVING}, nil
}

func (healthServer) Watch(*healthgrpc.HealthCheckRequest, healthgrpc.Health_WatchServer) error {
    return fmt.Errorf("watch is not implemented")
}

func main() {
    if err := run(); err != nil {
        log.Fatal(err)
    }
}

func run() error {
    if len(os.Args) < 2 {
        return fmt.Errorf("usage: %s server|client [flags]", os.Args[0])
    }
    switch os.Args[1] {
    case "server":
        return runServer(os.Args[2:])
    case "client":
        return runClient(os.Args[2:])
    default:
        return fmt.Errorf("unknown mode %q", os.Args[1])
    }
}

func runServer(args []string) error {
    flags := flag.NewFlagSet("server", flag.ContinueOnError)
    listenAddr := flags.String("listen", "10.30.0.1:50051", "listen address")
    if err := flags.Parse(args); err != nil {
        return err
    }
    listener, err := net.Listen("tcp", *listenAddr)
    if err != nil {
        return err
    }
    server := grpc.NewServer()
    healthgrpc.RegisterHealthServer(server, healthServer{})
    return server.Serve(listener)
}

func runClient(args []string) error {
    flags := flag.NewFlagSet("client", flag.ContinueOnError)
    target := flags.String("target", "10.30.0.1:50051", "server address")
    requests := flags.Int("requests", 1000, "measured requests")
    warmup := flags.Int("warmup", 50, "warmup requests")
    if err := flags.Parse(args); err != nil {
        return err
    }

    conn, err := grpc.Dial(*target, grpc.WithTransportCredentials(insecure.NewCredentials()))
    if err != nil {
        return err
    }
    defer conn.Close()

    client := healthgrpc.NewHealthClient(conn)
    latencies := make([]time.Duration, 0, *requests)
    failed := 0
    startAll := time.Now()
    for i := 0; i < *requests+*warmup; i++ {
        ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
        start := time.Now()
        _, err := client.Check(ctx, &healthgrpc.HealthCheckRequest{Service: "demo"})
        elapsed := time.Since(start)
        cancel()
        if err != nil {
            failed++
            continue
        }
        if i >= *warmup {
            latencies = append(latencies, elapsed)
        }
    }

    total := time.Since(startAll)
    sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
    count := len(latencies)
    avg := average(latencies)
    fmt.Printf("count=%d failed=%d qps=%.2f avg_us=%.2f p50_us=%.2f p95_us=%.2f p99_us=%.2f\n",
        count, failed, float64(count)/total.Seconds(),
        float64(avg)/float64(time.Microsecond), percentileUS(latencies, 0.50),
        percentileUS(latencies, 0.95), percentileUS(latencies, 0.99))
    if count == 0 {
        return fmt.Errorf("no successful requests")
    }
    return nil
}

func average(samples []time.Duration) time.Duration {
    if len(samples) == 0 {
        return 0
    }
    var total time.Duration
    for _, sample := range samples {
        total += sample
    }
    return total / time.Duration(len(samples))
}

func percentileUS(samples []time.Duration, percentile float64) float64 {
    if len(samples) == 0 {
        return 0
    }
    index := int(float64(len(samples)-1) * percentile)
    return float64(samples[index]) / float64(time.Microsecond)
}
EOF

  (cd "${go_work}" && go mod tidy && go build -o grpc-h2c-demo .)
}

extract_field() {
  local name="$1"
  local file="$2"
  tr ' ' '\n' < "$file" | awk -F= -v n="$name" '$1 == n { print $2; exit }'
}

need_cmd awk
need_cmd go
need_cmd ip

if [[ ! -x "${repo_dir}/build/grpc_monitor" ]]; then
  echo "missing build/grpc_monitor; run ./scripts/build_linux.sh first" >&2
  exit 1
fi

mkdir -p "${out_dir}"
trap cleanup EXIT
cleanup
write_go_demo

run_sudo ip netns add "${netns}"
run_sudo ip link add "${srv_if}" type veth peer name "${cli_if}"
run_sudo ip link set "${cli_if}" netns "${netns}"
run_sudo ip addr add "${srv_ip}/24" dev "${srv_if}"
run_sudo ip link set "${srv_if}" up
run_sudo ip netns exec "${netns}" ip addr add "${cli_ip}/24" dev "${cli_if}"
run_sudo ip netns exec "${netns}" ip link set lo up
run_sudo ip netns exec "${netns}" ip link set "${cli_if}" up

if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\\n' '${sudo_pass}' | sudo -S '${go_work}/grpc-h2c-demo' server --listen '${srv_ip}:${port}'" > "${out_dir}/server.log" 2>&1 &
else
  nohup sudo "${go_work}/grpc-h2c-demo" server --listen "${srv_ip}:${port}" > "${out_dir}/server.log" 2>&1 &
fi
sleep 1

pushd "${repo_dir}" >/dev/null
if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\\n' '${sudo_pass}' | sudo -S timeout '$((duration + 12))s' ./build/grpc_monitor --dev '${srv_if}' --port '${port}' --verbose-events" > "${out_dir}/grpc-monitor.log" 2>&1 &
else
  nohup sudo timeout "$((duration + 12))s" ./build/grpc_monitor --dev "${srv_if}" --port "${port}" --verbose-events > "${out_dir}/grpc-monitor.log" 2>&1 &
fi
monitor_pid=$!
popd >/dev/null

sleep 1
run_sudo ip netns exec "${netns}" "${go_work}/grpc-h2c-demo" client --target "${srv_ip}:${port}" --requests "${requests}" --warmup "${warmup}" > "${out_dir}/latency.log"

run_sudo pkill -TERM -f "grpc_monitor --dev ${srv_if}" >/dev/null 2>&1 || true
kill -TERM "${monitor_pid}" >/dev/null 2>&1 || true
wait "${monitor_pid}" >/dev/null 2>&1 || true
sleep 1

latency_line="$(cat "${out_dir}/latency.log")"
success_count="$(extract_field count "${out_dir}/latency.log")"
failed_count="$(extract_field failed "${out_dir}/latency.log")"
qps="$(extract_field qps "${out_dir}/latency.log")"
avg_us="$(extract_field avg_us "${out_dir}/latency.log")"
p50_us="$(extract_field p50_us "${out_dir}/latency.log")"
p95_us="$(extract_field p95_us "${out_dir}/latency.log")"
p99_us="$(extract_field p99_us "${out_dir}/latency.log")"
metrics_line="$(grep 'grpc_metrics' "${out_dir}/grpc-monitor.log" | tail -1 || true)"

cat > "${out_dir}/summary.md" <<MD
# gRPC h2c Monitor Benchmark

topology=netns+veth
server=${srv_ip}:${port}
client=${cli_ip}
requests=${requests}
warmup=${warmup}
service=grpc.health.v1.Health/Check

| metric | value |
| --- | ---: |
| success | ${success_count} |
| failed | ${failed_count} |
| qps | ${qps} |
| avg_us | ${avg_us} |
| p50_us | ${p50_us} |
| p95_us | ${p95_us} |
| p99_us | ${p99_us} |

latency bench: ${latency_line}

grpc monitor: ${metrics_line}
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"