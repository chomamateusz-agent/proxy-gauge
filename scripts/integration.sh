#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${CPA_BIN:-}"
if [[ -z "$binary" || ! -x "$binary" ]]; then
    echo "Set CPA_BIN to an executable stock CLIProxyAPI binary, for example make integration CPA_BIN=/path/to/cli-proxy-api." >&2
    exit 2
fi

port=""
for _ in $(seq 1 20); do
    candidate=$((9000 + RANDOM % 1000))
    if ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then
        port="$candidate"
        break
    fi
done
if [[ -z "$port" ]]; then
    echo "No free port in 9000-9999." >&2
    exit 1
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/proxygauge-integration.XXXXXX")"
chmod 700 "$workdir"
proxy_pid=""
cleanup() {
    if [[ -n "$proxy_pid" ]] && kill -0 "$proxy_pid" 2>/dev/null; then
        kill "$proxy_pid"
        wait "$proxy_pid" 2>/dev/null || true
    fi
    rm -rf "$workdir"
}
trap cleanup EXIT

umask 077
openssl rand -hex 24 > "$workdir/management.key"
openssl rand -hex 24 > "$workdir/client.key"
mkdir -p "$workdir/auth"
cat > "$workdir/config.yaml" <<YAML
config-version: 8
server:
  host: "127.0.0.1"
  port: $port
management:
  allow-remote: false
  secret-key: "$(cat "$workdir/management.key")"
  disable-control-panel: true
access:
  api-keys:
    - "$(cat "$workdir/client.key")"
oauth:
  auth-dir: "$workdir/auth"
routing:
  strategy: "round-robin"
YAML

"$binary" -config "$workdir/config.yaml" -local-model > "$workdir/proxy.log" 2>&1 &
proxy_pid=$!

for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
        echo "CLIProxyAPI exited during startup." >&2
        exit 1
    fi
    sleep 0.25
done
curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null
echo "Stock CLIProxyAPI $("$binary" --help 2>&1 | head -1 | sed 's/^CLIProxyAPI //') listening on 127.0.0.1:$port"

PROXY_GAUGE_INTEGRATION_URL="http://127.0.0.1:$port" \
PROXY_GAUGE_INTEGRATION_KEY_FILE="$workdir/management.key" \
PROXY_GAUGE_INTEGRATION_CLIENT_KEY_FILE="$workdir/client.key" \
    swift test --package-path "$root" --filter IntegrationTests

cleanup
proxy_pid=""
trap - EXIT
if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $port is still in use after stopping the proxy." >&2
    exit 1
fi
echo "Proxy stopped; port $port is free."
