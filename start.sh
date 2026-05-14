#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONFIG_PATH="${SCRIPT_DIR}/config.json"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

as_json_bool() {
    case "${1,,}" in
        true|1|yes|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

as_int_bool() {
    case "${1,,}" in
        true|1|yes|on) echo "1" ;;
        *) echo "0" ;;
    esac
}

detect_mem_kb() {
    awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0
}

get_cpu_limit_snapshot() {
    local quota="n/a"
    local period="n/a"
    local cpu_count
    local vcpu_available="n/a"
    local source="host"

    if [[ -f "/sys/fs/cgroup/cpu.max" ]]; then
        source="cgroupv2"
        read -r quota period < "/sys/fs/cgroup/cpu.max"

        if [[ "${quota}" != "max" ]] && [[ "${quota}" =~ ^[0-9]+$ ]] && [[ "${period}" =~ ^[0-9]+$ ]] && (( period > 0 )); then
            cpu_count=$(( (quota + period - 1) / period ))
            vcpu_available="$(awk -v q="${quota}" -v p="${period}" 'BEGIN { printf "%.2f", q / p }')"
            echo "${cpu_count}|${quota}|${period}|${vcpu_available}|${source}"
            return
        fi

        cpu_count="$(nproc 2>/dev/null || echo 1)"
        if [[ "${quota}" == "max" ]]; then
            vcpu_available="unlimited"
        fi
        echo "${cpu_count}|${quota}|${period}|${vcpu_available}|${source}"
        return
    fi

    if [[ -f "/sys/fs/cgroup/cpu/cpu.cfs_quota_us" ]] && [[ -f "/sys/fs/cgroup/cpu/cpu.cfs_period_us" ]]; then
        source="cgroupv1"
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"

        if [[ "${quota}" =~ ^[0-9]+$ ]] && [[ "${period}" =~ ^[0-9]+$ ]] && (( quota > 0 )) && (( period > 0 )); then
            cpu_count=$(( (quota + period - 1) / period ))
            vcpu_available="$(awk -v q="${quota}" -v p="${period}" 'BEGIN { printf "%.2f", q / p }')"
            echo "${cpu_count}|${quota}|${period}|${vcpu_available}|${source}"
            return
        fi

        cpu_count="$(nproc 2>/dev/null || echo 1)"
        if [[ "${quota}" == "-1" ]]; then
            vcpu_available="unlimited"
        fi
        echo "${cpu_count}|${quota}|${period}|${vcpu_available}|${source}"
        return
    fi

    cpu_count="$(nproc 2>/dev/null || echo 1)"
    vcpu_available="$(awk -v c="${cpu_count}" 'BEGIN { printf "%.2f", c + 0 }')"
    echo "${cpu_count}|${quota}|${period}|${vcpu_available}|${source}"
}

refresh_runtime_resources() {
    TOTAL_MEM_KB="$(detect_mem_kb)"
    TOTAL_MEM_MB=$(( TOTAL_MEM_KB / 1024 ))

    local cpu_snapshot
    cpu_snapshot="$(get_cpu_limit_snapshot)"
    IFS='|' read -r CPU_COUNT CPU_QUOTA CPU_PERIOD CPU_VCPU_AVAILABLE CPU_LIMIT_SOURCE <<< "${cpu_snapshot}"
}

dns_resolves() {
    local host="$1"
    getent ahosts "${host}" >/dev/null 2>&1
}

tcp_reachable() {
    local host="$1"
    local port="$2"

    if command -v timeout >/dev/null 2>&1; then
        timeout 3 bash -c ": >/dev/tcp/${host}/${port}" >/dev/null 2>&1
    else
        return 0
    fi
}

choose_randomx_mode() {
    local setting="${1,,}"
    local mem_mb="$2"

    case "${setting}" in
        true|1|yes|on|light) echo "light" ;;
        false|0|no|off|fast) echo "fast" ;;
        auto|"")
            if (( mem_mb < 3072 )); then
                echo "light"
            else
                echo "fast"
            fi
            ;;
        *)
            warn "Unknown LIGHT_MODE='${1}', using auto"
            if (( mem_mb < 3072 )); then echo "light"; else echo "fast"; fi
            ;;
    esac
}

calc_max_threads() {
    local mode="$1"
    local cpu_count="$2"
    local mem_mb="$3"
    local max_threads_by_mem

    if [[ "${mode}" == "fast" ]]; then
        # Fast RandomX needs ~2.3 GB dataset + overhead.
        if (( mem_mb < 3072 )); then
            max_threads_by_mem=1
        else
            max_threads_by_mem=$(( (mem_mb - 2300) / 128 ))
            (( max_threads_by_mem < 1 )) && max_threads_by_mem=1
        fi
    else
        # Light mode is much smaller; keep reserve for OS and health server.
        max_threads_by_mem=$(( (mem_mb - 384) / 256 ))
        (( max_threads_by_mem < 1 )) && max_threads_by_mem=1
    fi

    local cap="${MAX_THREADS_CAP:-0}"
    if [[ "${cap}" =~ ^[0-9]+$ ]] && (( cap > 0 )) && (( max_threads_by_mem > cap )); then
        max_threads_by_mem="${cap}"
    fi

    if (( max_threads_by_mem > cpu_count )); then
        max_threads_by_mem="${cpu_count}"
    fi

    (( max_threads_by_mem < 1 )) && max_threads_by_mem=1
    echo "${max_threads_by_mem}"
}

resolve_pool_endpoint() {
    local primary_host="$1"
    local primary_port="$2"
    local fallback_csv="$3"

    local candidates=("${primary_host}:${primary_port}")
    IFS=',' read -r -a parsed_fallbacks <<< "${fallback_csv}"
    for item in "${parsed_fallbacks[@]}"; do
        [[ -n "${item}" ]] && candidates+=("${item}")
    done

    for endpoint in "${candidates[@]}"; do
        local host="${endpoint%%:*}"
        local port="${endpoint##*:}"
        [[ -z "${host}" || -z "${port}" ]] && continue

        if dns_resolves "${host}" && tcp_reachable "${host}" "${port}"; then
            echo "${host}:${port}"
            return
        fi
    done

    fail "No reachable Monero pool endpoint found from configured candidates"
}

if [[ -n "${WALLET:-}" || -n "${WALLET_ADDRESS:-}" ]]; then
    log "Running in Docker mode (env vars injected)"
else
    [[ -f "${ENV_FILE}" ]] || fail ".env not found at ${ENV_FILE}"
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    log "Loaded environment from .env"
fi

WALLET="${WALLET:-${WALLET_ADDRESS:-}}"
POOL_URL="${POOL_URL:-${POOL_ADDRESS:-93.157.244.212}}"
POOL_PORT="${POOL_PORT:-3333}"
POOL_FALLBACKS="${POOL_FALLBACKS:-}"

WORKER_NAME="${WORKER_NAME:-$(hostname)}"
ALGO="${ALGO:-rx/0}"
COIN="${COIN:-monero}"
TLS_JSON="$(as_json_bool "${TLS:-false}")"
POOL_PASS="${POOL_PASS:-${PASSWORD:-x}}"
DONATE="${DONATE:-1}"
PRINT_TIME="${PRINT_TIME:-1}"
VERBOSE_LEVEL="${VERBOSE_LEVEL:-2}"
RAMP_INTERVAL_SEC="${RAMP_INTERVAL_SEC:-60}"
CPU_METRICS_LOG_INTERVAL_SEC="${CPU_METRICS_LOG_INTERVAL_SEC:-60}"
ADAPTIVE_THREADS_INT="$(as_int_bool "${ADAPTIVE_THREADS:-true}")"

[[ -n "${WALLET}" ]] || fail "WALLET (or WALLET_ADDRESS) is required"

if ! [[ "${DONATE}" =~ ^[0-9]+$ ]]; then DONATE="1"; fi
if (( DONATE < 1 )); then DONATE="1"; fi
if ! [[ "${PRINT_TIME}" =~ ^[0-9]+$ ]]; then PRINT_TIME="1"; fi
if ! [[ "${VERBOSE_LEVEL}" =~ ^[0-9]+$ ]]; then VERBOSE_LEVEL="2"; fi
if ! [[ "${RAMP_INTERVAL_SEC}" =~ ^[0-9]+$ ]]; then RAMP_INTERVAL_SEC="60"; fi
if ! [[ "${CPU_METRICS_LOG_INTERVAL_SEC}" =~ ^[0-9]+$ ]]; then CPU_METRICS_LOG_INTERVAL_SEC="60"; fi
if ! [[ "${POOL_PORT}" =~ ^[0-9]+$ ]]; then POOL_PORT="10001"; fi

refresh_runtime_resources

RANDOMX_MODE="$(choose_randomx_mode "${LIGHT_MODE:-auto}" "${TOTAL_MEM_MB}")"
if [[ "${RANDOMX_MODE}" == "light" ]]; then
    warn "RandomX light mode is enabled for low RAM. Expect much lower rewards vs fast mode."
fi

POOL_ENDPOINT="$(resolve_pool_endpoint "${POOL_URL}" "${POOL_PORT}" "${POOL_FALLBACKS}")"
POOL_URL="${POOL_ENDPOINT%%:*}"
POOL_PORT="${POOL_ENDPOINT##*:}"

TARGET_MAX_THREADS="$(calc_max_threads "${RANDOMX_MODE}" "${CPU_COUNT}" "${TOTAL_MEM_MB}")"

MANUAL_THREADS="${THREADS:-}"
if [[ -n "${MANUAL_THREADS}" ]]; then
    if ! [[ "${MANUAL_THREADS}" =~ ^[0-9]+$ ]]; then
        warn "Invalid THREADS='${MANUAL_THREADS}', fallback to 1"
        MANUAL_THREADS="1"
    fi
    CURRENT_THREADS="${MANUAL_THREADS}"
    ADAPTIVE_THREADS_INT=0
else
    CURRENT_THREADS=1
fi

if (( CURRENT_THREADS > TARGET_MAX_THREADS )); then
    CURRENT_THREADS="${TARGET_MAX_THREADS}"
fi
(( CURRENT_THREADS < 1 )) && CURRENT_THREADS=1

if [[ -x "/opt/xmrig/xmrig" ]]; then
    XMRIG_BIN="/opt/xmrig/xmrig"
elif [[ -x "${SCRIPT_DIR}/xmrig/xmrig" ]]; then
    XMRIG_BIN="${SCRIPT_DIR}/xmrig/xmrig"
else
    fail "XMRig binary not found. Expected /opt/xmrig/xmrig"
fi

write_config() {
    local threads="$1"
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
    "background": false,
    "colors": false,
    "cpu-affinity": null,
    "cpu-priority": 1,
    "donate-level": ${DONATE},
    "log-file": null,
    "no-color": true,
    "no-conf": false,
    "pools": [
        {
            "algo": "${ALGO}",
            "coin": "${COIN}",
            "url": "${POOL_URL}:${POOL_PORT}",
            "user": "${WALLET}",
            "pass": "${POOL_PASS}",
            "keepalive": true,
            "nicehash": false,
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
        "mode": "${RANDOMX_MODE}",
        "1gb-pages": false,
        "rdmsr": true
    },
    "cpu": {
        "enabled": true,
        "max-threads-hint": 100
    }
}
EOF
}

MINER_PID=""

start_miner() {
    local threads="$1"
    write_config "${threads}"

    "${XMRIG_BIN}" \
        --config "${CONFIG_PATH}" \
        --threads "${threads}" \
        --user-agent "Railway-XMR-${WORKER_NAME}" \
        --print-time "${PRINT_TIME}" &
    MINER_PID=$!
    log "Miner started: pid=${MINER_PID}, threads=${threads}, mode=${RANDOMX_MODE}, pool=${POOL_URL}:${POOL_PORT}"
}

stop_miner() {
    if [[ -n "${MINER_PID}" ]] && kill -0 "${MINER_PID}" 2>/dev/null; then
        kill -TERM "${MINER_PID}" 2>/dev/null || true
        set +e
        wait "${MINER_PID}" >/dev/null 2>&1
        set -e
    fi
    MINER_PID=""
}

cleanup() {
    stop_miner
}
trap cleanup SIGTERM SIGINT EXIT

WALLET_MASKED="${WALLET}"
if (( ${#WALLET} > 18 )); then
    WALLET_MASKED="${WALLET:0:10}...${WALLET: -8}"
fi

echo "============================================"
echo " Miner:          XMRig $(basename "${XMRIG_BIN}")"
echo " Coin:           XMR (${ALGO})"
echo " Pool:           ${POOL_URL}:${POOL_PORT}"
echo " Wallet:         ${WALLET_MASKED}"
echo " Worker:         ${WORKER_NAME}"
echo " CPUs seen:      ${CPU_COUNT}"
echo " vCPU available: ${CPU_VCPU_AVAILABLE}"
echo " CPU quota:      ${CPU_QUOTA}/${CPU_PERIOD} (${CPU_LIMIT_SOURCE})"
echo " RAM:            ${TOTAL_MEM_MB} MB"
echo " RandomX mode:   ${RANDOMX_MODE}"
echo " Max threads:    ${TARGET_MAX_THREADS}"
echo " Start threads:  ${CURRENT_THREADS}"
echo " Adaptive tune:  ${ADAPTIVE_THREADS_INT} (interval ${RAMP_INTERVAL_SEC}s)"
echo " Metrics every:  ${CPU_METRICS_LOG_INTERVAL_SEC}s"
echo " Print time:     ${PRINT_TIME}s"
echo "============================================"

start_miner "${CURRENT_THREADS}"
LAST_RAMP_TS="$(date +%s)"
LAST_METRICS_TS="${LAST_RAMP_TS}"

while true; do
    sleep 1

    if [[ -z "${MINER_PID}" ]] || ! kill -0 "${MINER_PID}" 2>/dev/null; then
        set +e
        wait "${MINER_PID}" 2>/dev/null
        EXIT_CODE=$?
        set -e
        warn "Miner exited with code ${EXIT_CODE}"

        if (( CURRENT_THREADS > 1 )); then
            CURRENT_THREADS=$((CURRENT_THREADS - 1))
            warn "Backoff after crash: threads -> ${CURRENT_THREADS}"
        fi

        sleep 3
        refresh_runtime_resources
        TARGET_MAX_THREADS="$(calc_max_threads "${RANDOMX_MODE}" "${CPU_COUNT}" "${TOTAL_MEM_MB}")"
        (( CURRENT_THREADS > TARGET_MAX_THREADS )) && CURRENT_THREADS="${TARGET_MAX_THREADS}"

        start_miner "${CURRENT_THREADS}"
        LAST_RAMP_TS="$(date +%s)"
        LAST_METRICS_TS="${LAST_RAMP_TS}"
        continue
    fi

    NOW_TS="$(date +%s)"
    if (( CPU_METRICS_LOG_INTERVAL_SEC > 0 )) && (( NOW_TS - LAST_METRICS_TS >= CPU_METRICS_LOG_INTERVAL_SEC )); then
        refresh_runtime_resources
        TARGET_MAX_THREADS="$(calc_max_threads "${RANDOMX_MODE}" "${CPU_COUNT}" "${TOTAL_MEM_MB}")"
        log "Resource snapshot: vCPU_available=${CPU_VCPU_AVAILABLE}, quota=${CPU_QUOTA}, period=${CPU_PERIOD}, cpus_seen=${CPU_COUNT}, ram_mb=${TOTAL_MEM_MB}, target_threads=${TARGET_MAX_THREADS}"
        LAST_METRICS_TS="${NOW_TS}"
    fi

    if (( ADAPTIVE_THREADS_INT == 1 )) && (( NOW_TS - LAST_RAMP_TS >= RAMP_INTERVAL_SEC )); then
        refresh_runtime_resources
        TARGET_MAX_THREADS="$(calc_max_threads "${RANDOMX_MODE}" "${CPU_COUNT}" "${TOTAL_MEM_MB}")"

        if (( CURRENT_THREADS < TARGET_MAX_THREADS )); then
            NEXT_THREADS=$((CURRENT_THREADS + 1))
            (( NEXT_THREADS > TARGET_MAX_THREADS )) && NEXT_THREADS="${TARGET_MAX_THREADS}"
            log "Adaptive ramp: ${CURRENT_THREADS} -> ${NEXT_THREADS}"
            stop_miner
            CURRENT_THREADS="${NEXT_THREADS}"
            start_miner "${CURRENT_THREADS}"
        elif (( CURRENT_THREADS > TARGET_MAX_THREADS )); then
            log "Adaptive downscale: ${CURRENT_THREADS} -> ${TARGET_MAX_THREADS}"
            stop_miner
            CURRENT_THREADS="${TARGET_MAX_THREADS}"
            start_miner "${CURRENT_THREADS}"
        else
            log "Adaptive check: threads=${CURRENT_THREADS}, target=${TARGET_MAX_THREADS} (no change)"
        fi

        LAST_RAMP_TS="${NOW_TS}"
    fi
done
