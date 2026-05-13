#!/bin/bash
set -euo pipefail

# ============================================================
#  XMRig Miner — start.sh
#  Optimized for low-resource servers: 2vCPU, 1GB RAM
#  Works in bare-metal and Docker modes
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Docker mode: env vars are injected directly ---
# --- Bare-metal mode: source .env ---
if [[ ! -z "${WALLET:-}" && "$WALLET" != "YOUR_WALLET_ADDRESS_HERE" ]]; then
    echo "[INFO] Running in Docker mode (env vars injected)"
else
    CONFIG_FILE="${SCRIPT_DIR}/.env"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "[ERROR] .env not found. Copy .env.example to .env and fill it in."
        exit 1
    fi
    source "$CONFIG_FILE"
fi

# --- Validation ---
if [[ -z "${WALLET:-}" || "$WALLET" == "YOUR_WALLET_ADDRESS_HERE" ]]; then
    echo "[ERROR] Set WALLET in .env or as env var"
    exit 1
fi

if [[ -z "${POOL_URL:-}" || -z "${POOL_PORT:-}" ]]; then
    echo "[ERROR] Set POOL_URL and POOL_PORT in .env or as env vars"
    exit 1
fi

# --- Defaults ---
: "${WORKER_NAME:=$(hostname)}"
: "${ALGO:=cn/r}"
: "${TLS:=false}"
: "${POOL_PASS:=x}"
: "${DONATE:=1}"

# --- Auto-detect threads ---
if [[ -z "${THREADS:-}" ]]; then
    THREADS="$(nproc 2>/dev/null || echo 2)"
fi

# Cap threads for small servers
if [[ -f /proc/meminfo ]]; then
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if (( TOTAL_MEM_KB < 2097152 )); then
        echo "[INFO] Low-RAM server (${TOTAL_MEM_KB}KB). Capping threads to 2."
        (( THREADS > 2 )) && THREADS=2
    fi
else
    TOTAL_MEM_KB="unknown"
fi

# --- Find XMRig binary ---
if [[ -x "/opt/xmrig/xmrig" ]]; then
    XMRIG_BIN="/opt/xmrig/xmrig"
elif [[ -x "${SCRIPT_DIR}/xmrig/xmrig" ]]; then
    XMRIG_BIN="${SCRIPT_DIR}/xmrig/xmrig"
else
    echo "[INFO] XMRig binary not found. Downloading v6.26.0..."
    mkdir -p "${SCRIPT_DIR}/xmrig"
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    RELEASE="xmrig-6.26.0-linux-${ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/xmrig/xmrig/releases/download/v6.26.0/${RELEASE}"
    curl -fsSL "$DOWNLOAD_URL" -o "/tmp/${RELEASE}"
    tar -xzf "/tmp/${RELEASE}" -C "${SCRIPT_DIR}/xmrig/" --strip-components=1
    chmod +x "${SCRIPT_DIR}/xmrig/xmrig"
    rm -f "/tmp/${RELEASE}"
    XMRIG_BIN="${SCRIPT_DIR}/xmrig/xmrig"
    echo "[OK] XMRig installed."
fi

# --- Build config.json ---
cat > config.json << EOF
{
    "api": {
        "id": null,
        "worker-id": null,
        "level": 1,
        "no-notes": false,
        "restricted": false,
        "safe-curls": true
    },
    "av": 0,
    "background": true,
    "colors": false,
    "cpu-affinity": null,
    "cpu-priority": 1,
    "donate-level": ${DONATE:-1},
    "ignore-bad-packages": false,
    "large-pages-num": 0,
    "log-file": null,
    "no-color": true,
    "no-conf": false,
    "pools": [
        {
            "algo": "${ALGO:-cn/ccx}",
            "coin": "ccx",
            "url": "${POOL_URL:-mine.conceal.network}:${POOL_PORT:-16055}",
            "user": "${WALLET}",
            "pass": "${POOL_PASS:-x}",
            "keepalive": true,
            "nicehash": false,
            "variant": -1,
            "enabled": true,
            "tls": ${TLS:-false}
        }
    ],
    "rebinds": 0,
    "resume-retries": 10,
    "resume-retry-pause": 5,
    "syslog": false,
    "tls": {
        "enabled": ${TLS:-false}
    },
    "verbose": 3,
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

# --- Build command ---
CMD=(
    "$XMRIG_BIN"
    "--config" "config.json"
    "--threads" "$THREADS"
    "--user-agent" "CCX-${WORKER_NAME}"
)

echo "============================================"
echo " Miner:   XMRig $(basename "$XMRIG_BIN")"
echo " Coin:    CCX (${ALGO})"
echo " Pool:    ${POOL_URL}:${POOL_PORT}"
echo " Wallet:  ${WALLET}"
echo " Worker:  ${WORKER_NAME}"
echo " Threads: ${THREADS}"
echo " RAM:     $(( ${TOTAL_MEM_KB:-0} / 1024 )) MB"
echo "============================================"

echo "[INFO] Starting CCX Miner..."
exec "${CMD[@]}"
