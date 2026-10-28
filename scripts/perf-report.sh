#!/bin/bash
# Summarize MainThreadWatchdog stalls ([perf] lines) for a time window.
#   scripts/perf-report.sh --last 30m            unified log, last 30 minutes (m/h/d)
#   scripts/perf-report.sh --start "2026-10-28 13:00:00" [--end "…"]
#   add --file [PATH] to read the Debug file log instead of the unified log
set -euo pipefail

LAST="" START="" END="" FILE=""
DEFAULT_FILE="$HOME/Library/Logs/HyprMac/com.zachgray.HyprMac.debug.log"
while [ $# -gt 0 ]; do
    case "$1" in
        --last)  LAST="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --end)   END="$2"; shift 2 ;;
        --file)
            if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then FILE="$2"; shift 2; else FILE="$DEFAULT_FILE"; shift; fi ;;
        *) sed -n '2,5p' "$0"; exit 2 ;;
    esac
done
if [ -z "$LAST" ] && [ -z "$START" ]; then LAST=30m; fi

if [ -n "$LAST" ]; then
    n="${LAST%[mhd]}" u="${LAST: -1}"
    case "$u" in m) secs=$((n * 60)) ;; h) secs=$((n * 3600)) ;; d) secs=$((n * 86400)) ;; *) echo "bad --last: $LAST" >&2; exit 2 ;; esac
    end_epoch=$(date +%s)
    start_epoch=$((end_epoch - secs))
    START=$(date -r "$start_epoch" '+%Y-%m-%d %H:%M:%S')
    END=$(date -r "$end_epoch" '+%Y-%m-%d %H:%M:%S')
else
    END="${END:-$(date '+%Y-%m-%d %H:%M:%S')}"
    start_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$START" +%s)
    end_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$END" +%s)
fi
hours=$(awk -v s="$((end_epoch - start_epoch))" 'BEGIN { printf "%.2f", s / 3600 }')

if [ -n "$FILE" ]; then
    # file lines start with 2026-10-28T13:00:00.123+0100; local-time string compare
    awk -v s="${START/ /T}" -v e="${END/ /T}" '$1 >= s && $1 <= e && / \[perf\] /' "$FILE"
else
    /usr/bin/log show --style compact --start "$START" --end "$END" \
        --predicate 'subsystem BEGINSWITH "com.zachgray.HyprMac" AND category == "perf"'
fi | awk -v hours="$hours" -v win="$START → $END" '
    function offender(line,   o) {
        o = line
        if (!sub(/.*earlier: /, "", o)) { sub(/.* ms — /, "", o) }
        gsub(/0x[0-9a-fA-F]+/, "N", o)
        gsub(/[0-9]+(\.[0-9]+)?/, "N", o)
        return substr(o, 1, 120)
    }
    # nearest-rank percentile index
    function rank(p,   r) { r = int(p * n); if (r < p * n) r++; return r < 1 ? 1 : r }
    /main thread stalled [0-9]+ ms/ {
        match($0, /stalled [0-9]+ ms/)
        ms = substr($0, RSTART + 8, RLENGTH - 11) + 0
        stalls[++n] = ms; total += ms
        top[offender($0)]++
        pending = 0
        next
    }
    /main thread blocked [0-9]+ ms so far/ {
        match($0, /blocked [0-9]+ ms/)
        pending = substr($0, RSTART + 8, RLENGTH - 11) + 0
        pendingLine = offender($0)
    }
    END {
        printf "window      %s (%s h)\n", win, hours
        printf "stalls      %d (%.1f/h)\n", n, (hours > 0 ? n / hours : 0)
        if (n > 0) {
            # insertion sort is fine for a few hundred stalls
            for (i = 2; i <= n; i++) { v = stalls[i]; for (j = i - 1; j >= 1 && stalls[j] > v; j--) stalls[j + 1] = stalls[j]; stalls[j + 1] = v }
            p50 = stalls[rank(0.5)]; p90 = stalls[rank(0.9)]
            printf "stalled ms  total %d  p50 %d  p90 %d  max %d\n", total, p50, p90, stalls[n]
            print "top last-main-log:"
            for (k in top) printf "%6d  %s\n", top[k], k | "sort -rn | head -10"
            close("sort -rn | head -10")
        }
        if (pending) printf "UNRECOVERED blocked %d ms so far (no stalled line after): %s\n", pending, pendingLine
    }'
