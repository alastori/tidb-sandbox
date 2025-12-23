#!/bin/bash
# Common functions for lab scripts

# Disable color output for tiup and other tools that respect NO_COLOR
export NO_COLOR=1

# Reduce tiup progress spinner frequency (default 50ms, set to 5s for cleaner logs)
export TIUP_CLUSTER_PROGRESS_REFRESH_RATE=5s

# Strip ANSI escape codes and control characters from a file
# Usage: clean_log results/step0-output.log
clean_log() {
    local file="$1"
    if [ -f "$file" ]; then
        # Strip ANSI codes and carriage returns
        sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$file" | tr -d '\r' > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

# Clean all log files in the results directory
# Usage: clean_all_logs
clean_all_logs() {
    local results_dir="${LAB_DIR:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")}/results"
    if [ -d "$results_dir" ]; then
        for log in "$results_dir"/*.log; do
            [ -f "$log" ] && clean_log "$log"
        done
    fi
}

# Find mysql client (check common locations)
find_mysql() {
    if command -v mysql &>/dev/null; then
        echo "mysql"
    elif [ -x "/opt/homebrew/opt/mysql-client/bin/mysql" ]; then
        echo "/opt/homebrew/opt/mysql-client/bin/mysql"
    elif [ -x "/usr/local/opt/mysql-client/bin/mysql" ]; then
        echo "/usr/local/opt/mysql-client/bin/mysql"
    elif [ -x "/usr/local/bin/mysql" ]; then
        echo "/usr/local/bin/mysql"
    else
        echo ""
    fi
}

# Initialize MYSQL_CMD if not already set
init_mysql() {
    if [ -z "${MYSQL_CMD:-}" ]; then
        MYSQL_CMD=$(find_mysql)
        if [ -z "$MYSQL_CMD" ]; then
            echo "ERROR: mysql client not found. Please install mysql-client."
            echo "  macOS: brew install mysql-client"
            echo "  Linux: apt-get install mysql-client"
            exit 1
        fi
        export MYSQL_CMD
    fi
}