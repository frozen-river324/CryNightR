#!/bin/bash
set -euo pipefail

# ============================================================
#  Deploy miner to multiple servers via SSH
#  Usage: ./deploy.sh [server1] [server2] ...
#         ./deploy.sh -f servers.txt
# ============================================================

REPO_URL="${REPO_URL:-https://github.com/frozen-river324/CryNightR.git}"
BRANCH="${BRANCH:-main}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"

usage() {
    echo "Usage:"
    echo "  $0 server1 server2 server3     Deploy to listed servers"
    echo "  $0 -f servers.txt              Deploy to servers from file"
    echo ""
    echo "Env vars:"
    echo "  REPO_URL  - Git repo URL (required)"
    echo "  BRANCH    - Git branch (default: main)"
    echo "  SSH_USER  - SSH username (default: root)"
    echo "  SSH_KEY   - Path to SSH private key"
    exit 1
}

deploy_to_server() {
    local host="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
    [[ -n "$SSH_KEY" ]] && ssh_opts="$ssh_opts -i $SSH_KEY"

    echo "----------------------------------------"
    echo " Deploying to: ${SSH_USER}@${host}"

    ssh $ssh_opts "${SSH_USER}@${host}" bash -s << 'REMOTE_SCRIPT'
set -euo pipefail

echo "[1/4] Cloning miner repo..."
rm -rf /opt/ccx-miner
git clone --branch "$BRANCH" --depth 1 "$REPO_URL" /opt/ccx-miner

echo "[2/4] Setting up .env..."
cd /opt/ccx-miner
if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "[!] Created .env from .env.example — EDIT IT with your wallet/pool!"
fi

echo "[3/4] Installing dependencies..."
apt-get update -qq && apt-get install -y -qq curl ca-certificates git >/dev/null 2>&1 || true

echo "[4/4] Starting miner..."
chmod +x start.sh
bash start.sh &

echo "[OK] Miner started on $(hostname)"
REMOTE_SCRIPT

    local exit_code=$?
    if (( exit_code == 0 )); then
        echo "[OK] Deployed to ${host}"
    else
        echo "[FAIL] Could not deploy to ${host} (exit: ${exit_code})"
    fi
    echo ""
}

# --- Parse args ---
SERVERS=()
if [[ "${1:-}" == "-f" ]]; then
    [[ -z "${2:-}" ]] && usage
    while IFS= read -r line; do
        [[ -n "$line" && ! "$line" =~ ^# ]] && SERVERS+=("$line")
    done < "$2"
else
    [[ $# -eq 0 ]] && usage
    SERVERS=("$@")
fi

[[ -z "$REPO_URL" ]] && echo "ERROR: Set REPO_URL env var" && usage

echo "============================================"
echo " Deploying to ${#SERVERS[@]} server(s)"
echo " Repo: $REPO_URL"
echo " Branch: $BRANCH"
echo "============================================"
echo ""

for server in "${SERVERS[@]}"; do
    deploy_to_server "$server" &
done

wait
echo "============================================"
echo " Deployment complete."
echo " Remember to edit .env on each server!"
echo "============================================"
