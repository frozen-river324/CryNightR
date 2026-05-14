#!/bin/bash
# Stop the Monero miner

if pidof xmrig >/dev/null 2>&1; then
    echo "Stopping XMRig..."
    pkill -f xmrig || true
    echo "Miner stopped."
else
    echo "Miner is not running."
fi
