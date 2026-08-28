#!/bin/sh

# URL to check
URL="http://localhost:11470/stats.json"

# Process name
PROCESS_NAME="node server.js"

# Memory safety net: restart if RSS grows too large.
# This is a mitigation for upstream memory not being released promptly.
MAX_RSS_MB="${MAX_RSS_MB:-3200}"
MAX_RSS_BREACHES="${MAX_RSS_BREACHES:-1}" # consecutive healthcheck runs
BREACH_FILE="/tmp/stremio_rss_breaches"

# Return RSS for $PROCESS_NAME in MB (integer, best-effort).
rss_mb() {
    # ps inside the container supports: pid,rss,args
    rss_raw="$(ps -eo pid,rss,args 2>/dev/null | awk "/${PROCESS_NAME//./\\.}/ {print \\$2; exit}")"
    [ -z "$rss_raw" ] && echo 0 && return 0

    # ps implementations vary:
    # - Sometimes RSS is shown as KB (integer)
    # - Sometimes it is shown as "123m"/"1.2g" (human units)
    # We normalize all forms to integer MB.
    unit="${rss_raw##*[0-9.]}"
    num="${rss_raw%$unit}"

    # If we couldn't infer a unit, treat as KB.
    if [ "$unit" = "$rss_raw" ]; then
        echo $((rss_raw/1024))
        return 0
    fi

    case "$unit" in
      m|M)
        echo "$num" | awk '{print int($1)}'
        ;;
      g|G)
        # Allow float in $num (e.g. 1.7g)
        echo "$num" | awk '{printf "%d\n", ($1*1024)}'
        ;;
      k|K)
        # num is KB -> MB
        echo "$num" | awk '{printf "%d\n", ($1/1024)}'
        ;;
      *)
        # Unknown unit: assume KB.
        echo $((rss_raw/1024))
        ;;
    esac
}

# Function to restart the process
restart_process() {
    echo "$1" > /proc/1/fd/1 2>/proc/1/fd/2
    pkill -f "$PROCESS_NAME"
    nohup $PROCESS_NAME > /proc/1/fd/1 2>/proc/1/fd/2 &
    echo "Process restarted." > /proc/1/fd/1 2>/proc/1/fd/2
}

# Check if force restart is requested
if [ "$1" = "--force" ]; then
    restart_process "Force restart requested. Restarting the process..."
    exit 0
fi

# Memory threshold check
rss="$(rss_mb)"
if [ "$rss" -ge "$MAX_RSS_MB" ]; then
    breaches="$(cat "$BREACH_FILE" 2>/dev/null || echo 0)"
    breaches="$((breaches+1))"
    echo "$breaches" > "$BREACH_FILE" 2>/dev/null || true
    if [ "$breaches" -ge "$MAX_RSS_BREACHES" ]; then
        echo "RSS guard: RSS=${rss}MB max=${MAX_RSS_MB}MB breaches=${breaches}/${MAX_RSS_BREACHES} -> restarting" > /proc/1/fd/1 2>/proc/1/fd/2
        restart_process "RSS threshold exceeded: ${rss}MB >= ${MAX_RSS_MB}MB"
    else
        echo "RSS threshold breached (${breaches}/${MAX_RSS_BREACHES}); waiting for next check." > /proc/1/fd/1 2>/proc/1/fd/2
    fi
else
    echo 0 > "$BREACH_FILE" 2>/dev/null || true
fi

# Make the HTTP call
response=$(curl -s --max-time 5 "$URL")
curl_exit_status=$?

# Check if curl failed (non-zero exit status)
if [ $curl_exit_status -ne 0 ]; then
    restart_process "Curl failed with connection error. Restarting the process..."
# Check if the response is an empty JSON object
elif [ "$response" = "{}" ]; then
    restart_process "Empty JSON response detected. Restarting the process..."
else
    echo "Non-empty JSON response. No action needed." > /proc/1/fd/1 2>/proc/1/fd/2
fi
