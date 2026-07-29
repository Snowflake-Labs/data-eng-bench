#!/bin/bash
# Wait for entrypoint to complete before running any command
# This script is sourced by login shells (bash -l) via /etc/profile.d/

# Send wait messages to stderr so they don't interfere with command stdout
# (Harbor parses stdout of commands like "tmux -V")
if [ ! -f /tmp/entrypoint_ready ]; then
    echo "Waiting for environment initialization..." >&2
    TIMEOUT=2000
    ELAPSED=0
    while [ ! -f /tmp/entrypoint_ready ]; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "ERROR: Timed out waiting for initialization (${TIMEOUT}s)" >&2
            exit 1
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            echo "  Still initializing... (${ELAPSED}s elapsed)" >&2
        fi
    done
    echo "Environment ready!" >&2
fi

# Source Snowflake env vars if available
[ -f /tmp/snowflake_env.sh ] && source /tmp/snowflake_env.sh