#!/bin/bash
# Monitor packet loss and latency between AmneziaWG nodes.
# Usage: ./monitor_tunnel.sh <IP_ADDRESS>
# Logs to /var/log/awg_monitor.log with automatic rotation at 10MB (keeps 3 archives).

if [ -z "$1" ]; then
    echo "Usage: ./monitor_tunnel.sh <IP_ADDRESS>"
    exit 1
fi

TARGET=$1
LOGFILE="/var/log/awg_monitor.log"
MAX_SIZE=$((10 * 1024 * 1024))  # 10 MB
KEEP_ARCHIVES=3
PING_COUNT=10

rotate_log() {
    if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE")" -ge "$MAX_SIZE" ]; then
        # Shift old archives
        for i in $(seq $((KEEP_ARCHIVES - 1)) -1 1); do
            [ -f "${LOGFILE}.${i}.gz" ] && mv "${LOGFILE}.${i}.gz" "${LOGFILE}.$((i + 1)).gz"
        done
        # Compress and rotate current log
        gzip -c "$LOGFILE" > "${LOGFILE}.1.gz"
        > "$LOGFILE"
        echo "[$(date "+%Y-%m-%d %H:%M:%S")] Log rotated." >> "$LOGFILE"
    fi
}

echo "[$(date "+%Y-%m-%d %H:%M:%S")] Starting tunnel monitoring for $TARGET..." >> "$LOGFILE"

while true; do
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

    PING_OUT=$(ping -c $PING_COUNT -q "$TARGET" 2>&1)

    LOSS=$(echo "$PING_OUT" | grep -oP '\d+(?=% packet loss)')
    LATENCY=$(echo "$PING_OUT" | grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' | cut -d'/' -f2)

    if [ -z "$LOSS" ]; then
        LOSS="100"
        LATENCY="timeout"
    fi

    LOG_MSG="[$TIMESTAMP] Target: $TARGET | Loss: ${LOSS}% | Avg RTT: ${LATENCY}ms"
    echo "$LOG_MSG" >> "$LOGFILE"

    if [ "$LOSS" -gt 20 ]; then
        echo "[$TIMESTAMP] WARNING: High packet loss! (${LOSS}%)" >> "$LOGFILE"
    fi

    rotate_log
    sleep 60
done
