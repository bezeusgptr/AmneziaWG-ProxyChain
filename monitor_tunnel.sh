#!/bin/bash
# A simple script to monitor packet loss and latency between AmneziaWG nodes.
# Usage: ./monitor_tunnel.sh <IP_ADDRESS>

if [ -z "$1" ]; then
    echo "Usage: ./monitor_tunnel.sh <IP_ADDRESS>"
    exit 1
fi

TARGET=$1
LOGFILE="/var/log/awg_monitor.log"
PING_COUNT=10

echo "Starting tunnel monitoring for $TARGET..."
echo "Logs will be written to $LOGFILE"

while true; do
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Run ping and extract packet loss and avg latency
    PING_OUT=$(ping -c $PING_COUNT -q "$TARGET" 2>&1)
    
    LOSS=$(echo "$PING_OUT" | grep -oP '\d+(?=% packet loss)')
    LATENCY=$(echo "$PING_OUT" | grep -oP 'min/avg/max/mdev = \K[^/]+/[^/]+' | cut -d'/' -f2)
    
    if [ -z "$LOSS" ]; then
        LOSS="100"
        LATENCY="timeout"
    fi
    
    LOG_MSG="[$TIMESTAMP] Target: $TARGET, Packet Loss: $LOSS%, Avg Latency: ${LATENCY}ms"
    
    echo "$LOG_MSG" >> "$LOGFILE"
    
    if [ "$LOSS" -gt 20 ]; then
        echo "WARNING: High packet loss detected at $TIMESTAMP! ($LOSS%)" >> "$LOGFILE"
    fi
    
    # Wait for 60 seconds before next check
    sleep 60
done
