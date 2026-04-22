#!/bin/bash
# Prints current date/time every second
# Reads user input when available
# Usage: ./clock.sh

while true; do
    # Print date with seconds
    echo -ne "\r\033[K[$(date '+%Y-%m-%d %H:%M:%S')]> "

    # Read with 1-second timeout
    if read -t 1 -r user_input; then
        if [ -n "$user_input" ]; then
            echo "Command from user: ${user_input}"
        fi
    fi
done
