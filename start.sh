#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONFIG_PATH="${SCRIPT_DIR}/config.json"

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*"
}

fail() {
    echo "[ERROR] $*" >&2
    exit 1
}

as_json_bool() {
    case "${1,,}" in
        true|1|yes|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

detect_cpus() {
    # cgroup v2
    if [[ -f "/sys/fs/cgroup/cpu.max" ]]; then
        read -r quota period < "/sys/fs/cgroup/cpu.max"
        if [[ "${quota}" != "max" ]] && [[ "${quota}" =~ ^[0-9]+$ ]] && [[ "${period}" =~ ^[0-9]+$ ]] && (( period > 0 )); then
            echo $(( (quota + period - 1) / period ))
            return
        fi
    fi

    # cgroup v1
    if [[ -f "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" ]] && [[ -f "/sys/fs/cgroup/cpu/cpu.cfs_period_us" ]]; then
        local quota period
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
        if [[ "${quota}" =~ ^[0-9]+$ ]] && [[ "${period}" =~ ^[0-9]+$ ]] && (( quota > 0 )) && (( period > 0 )); then
            echo $(( (quota + period - 1) / period ))
            return
        fi
    fi

    nproc 2>/dev/null || echo 1
}

detect_mem_kb() {
    awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0
}

dns_resolves() {
    local host="$1"
    getent ahosts "${host}" >/dev/null 2>&1
}

tcp_reachable() {
    local host="$1"
    local port="$2"

    # Avoid hanging forever if network is blocked.
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 bash -c ": >/dev/tcp/${host}/${port}" >/dev/null 2>&1
    else
        # If timeout is unavailable, skip hard fail and assume reachable.
        return 0
    fi
}

if [[ -n "${WALLET:-}" ]] && [[ "${WALLET}" != "YOUR_WALLET_ADDRESS_HERE" ]]; then
    log "Running in Docker mode (env vars injected)"
else
    [[ -f "${ENV_FILE}" ]] || fail ".env not found at ${ENV_FILE}"
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    log "Loaded environment from .env"
fi

POOL_URL="${POOL_URL:-pool.conceal.network}"
POOL_PORT="${POOL_PORT:-3333}"
WORKER_NAME="${WORKER_NAME:-$(hostname)}"
ALGO="${ALGO:-cn/ccx}"
TLS_JSON="$(as_json_bool "${TLS:-false}")"
POOL_PASS="${POOL_PASS:-x}"
DONATE="${DONATE:-1}"
PRINT_TIME="${PRINT_TIME:-10}"
VERBOSE_LEVEL="${VERBOSE_LEVEL:-3}"

[[ -n "${WALLET:-}" ]] || fail "WALLET is required"
[[ -n "${POOL_URL}" ]] || fail "POOL_URL is required"
[[ -n "${POOL_PORT}" ]] || fail "POOL_PORT is required"

if ! [[ "${DONATE}" =~ ^[0-9]+$ ]]; then
    warn "Invalid DONATE='${DONATE}', using 1"
    DONATE="1"
fi

if (( DONATE < 1 )); then
    warn "Official XMRig binaries do not allow donate-level below 1%. Using 1%."
    DONATE="1"
fi

if ! [[ "${PRINT_TIME}" =~ ^[0-9]+$ ]]; then
    warn "Invalid PRINT_TIME='${PRINT_TIME}', using 10"
    PRINT_TIME="10"
fi

if ! [[ "${VERBOSE_LEVEL}" =~ ^[0-9]+$ ]]; then
    warn "Invalid VERBOSE_LEVEL='${VERBOSE_LEVEL}', using 3"
    VERBOSE_LEVEL="3"
fi

if ! [[ "${POOL_PORT}" =~ ^[0-9]+$ ]]; then
    warn "Invalid POOL_PORT='${POOL_PORT}', using 3333"
    POOL_PORT="3333"
fi

# Pool DNS fallback (this was the main runtime failure in Railway logs).
if ! dns_resolves "${POOL_URL}"; then
    warn "POOL_URL '${POOL_URL}' does not resolve. Trying known CCX pool hosts..."
    for host in pool.conceal.network mine.conceal.network; do
        if dns_resolves "${host}"; then
            POOL_URL="${host}"
            log "Using fallback pool host: ${POOL_URL}"
            break
        fi
    done
fi

if ! dns_resolves "${POOL_URL}"; then
    fail "No resolvable pool host found. Set POOL_URL manually in Railway variables."
fi

# Port fallback for common Conceal pool ports.
if ! tcp_reachable "${POOL_URL}" "${POOL_PORT}"; then
    warn "Pool ${POOL_URL}:${POOL_PORT} is not reachable. Trying fallback ports..."
    for p in 3333 5555 7777; do
        if tcp_reachable "${POOL_URL}" "${p}"; then
            POOL_PORT="${p}"
            log "Using fallback pool port: ${POOL_PORT}"
            break
        fi
    done
fi

TOTAL_MEM_KB="$(detect_mem_kb)"
CPU_COUNT="$(detect_cpus)"
THREADS="${THREADS:-${CPU_COUNT}}"

if ! [[ "${THREADS}" =~ ^[0-9]+$ ]]; then
    warn "Invalid THREADS='${THREADS}', using CPU count=${CPU_COUNT}"
    THREADS="${CPU_COUNT}"
fi

# Conservative caps for small containers
if (( TOTAL_MEM_KB > 0 )) && (( TOTAL_MEM_KB < 2097152 )) && (( THREADS > 2 )); then
    THREADS=2
elif (( TOTAL_MEM_KB >= 2097152 )) && (( TOTAL_MEM_KB < 4194304 )) && (( THREADS > 4 )); then
    THREADS=4
fi

(( THREADS >= 1 )) || THREADS=1

if [[ -x "/opt/xmrig/xmrig" ]]; then
    XMRIG_BIN="/opt/xmrig/xmrig"
elif [[ -x "${SCRIPT_DIR}/xmrig/xmrig" ]]; then
    XMRIG_BIN="${SCRIPT_DIR}/xmrig/xmrig"
else
    fail "XMRig binary not found. Expected /opt/xmrig/xmrig"
fi

cat > "${CONFIG_PATH}" << EOF
{
    "api": {
        "id": null,
        "worker-id": null,
        "level": 1,
        "no-notes": false,
        "restricted": false,
        "safe-curls": true
    },
    "http": {
        "enabled": false,
        "host": "127.0.0.1",
        "port": 0
    },
    "av": 0,
    "background": false,
    "colors": false,
    "cpu-affinity": null,
    "cpu-priority": 1,
    "donate-level": ${DONATE},
    "ignore-bad-packages": false,
    "large-pages-num": 0,
    "log-file": null,
    "no-color": true,
    "no-conf": false,
    "pools": [
        {
            "algo": "${ALGO}",
            "coin": "ccx",
            "url": "${POOL_URL}:${POOL_PORT}",
            "user": "${WALLET}",
            "pass": "${POOL_PASS}",
            "keepalive": true,
            "nicehash": false,
            "variant": -1,
            "enabled": true,
            "tls": ${TLS_JSON}
        }
    ],
    "rebinds": 0,
    "resume-retries": 10,
    "resume-retry-pause": 5,
    "syslog": false,
    "tls": {
        "enabled": ${TLS_JSON}
    },
    "verbose": ${VERBOSE_LEVEL},
    "pause-on-battery": false,
    "pause-on-active": false,
    "randomx": {
        "init": -1,
        "numa": true,
        "mode": "auto",
        "1gb-pages": false,
        "rdmsr": true
    }
}
EOF

WALLET_MASKED="${WALLET}"
if (( ${#WALLET} > 18 )); then
    WALLET_MASKED="${WALLET:0:10}...${WALLET: -8}"
fi

echo "============================================"
echo " Miner:      XMRig $(basename "${XMRIG_BIN}")"
echo " Coin:       CCX (${ALGO})"
echo " Pool:       ${POOL_URL}:${POOL_PORT}"
echo " Wallet:     ${WALLET_MASKED}"
echo " Worker:     ${WORKER_NAME}"
echo " CPUs seen:  ${CPU_COUNT}"
echo " Threads:    ${THREADS}"
echo " RAM:        $(( TOTAL_MEM_KB / 1024 )) MB"
echo " Print time: ${PRINT_TIME}s"
echo "============================================"

CMD=(
    "${XMRIG_BIN}"
    "--config" "${CONFIG_PATH}"
    "--threads" "${THREADS}"
    "--user-agent" "CCX-${WORKER_NAME}"
    "--print-time" "${PRINT_TIME}"
)

log "Starting CCX Miner in foreground"
exec "${CMD[@]}"
