#!/bin/bash
# Check miner status

echo "=== CCX Miner Status ==="

if pidof xmrig >/dev/null 2>&1; then
    PID=$(pidof xmrig | awk '{print $1}')
    echo "Status:    RUNNING"
    echo "PID:       $PID"
    echo "Threads:   $(ps -o nlwp= -p $PID 2>/dev/null || echo '?')"
    echo "CPU:       $(ps -o %cpu= -p $PID 2>/dev/null || echo '?')%"
    echo "Memory:    $(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%.0f MB", $1/1024}')"
    echo "Uptime:    $(ps -o etime= -p $PID 2>/dev/null || echo '?')"
else
    echo "Status:    STOPPED"
fi

echo ""
echo "System:"
echo "  Load:    $(uptime | awk -F'load average:' '{print $2}')"
echo "  RAM:     $(free -h 2>/dev/null | awk '/Mem:/{printf "%s / %s (%s free)", $3, $2, $4}' || echo 'N/A')"
echo "  Temp:    $(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | awk '{printf "%.0fC", $1/1000}' || echo 'N/A')"
