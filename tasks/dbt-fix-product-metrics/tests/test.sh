#!/bin/bash

# Source Snowflake env vars if available
if [ -f /tmp/snowflake_env.sh ]; then
    source /tmp/snowflake_env.sh
fi

mkdir -p /logs/verifier

# Run pytest and capture output
pytest_output=$(pytest /tests/test_outputs.py -v 2>&1)
exit_code=$?
echo "$pytest_output"

# Extract test counts from pytest summary
passed_count=$(echo "$pytest_output" | grep -oP '\d+(?= passed)' | tail -1)
skipped_count=$(echo "$pytest_output" | grep -oP '\d+(?= skipped)' | tail -1)
failed_count=$(echo "$pytest_output" | grep -oP '\d+(?= failed)' | tail -1)

passed_count=${passed_count:-0}
skipped_count=${skipped_count:-0}
failed_count=${failed_count:-0}

echo "Test results: $passed_count passed, $skipped_count skipped, $failed_count failed"

# Pass ONLY if all tests passed (no skips, no failures)
if [ $exit_code -eq 0 ] && [ "$passed_count" -gt 0 ] && [ "$skipped_count" -eq 0 ] && [ "$failed_count" -eq 0 ]; then
    echo 1 > /logs/verifier/reward.txt
    echo "SUCCESS: All $passed_count tests passed"
else
    echo 0 > /logs/verifier/reward.txt
    if [ "$skipped_count" -gt 0 ]; then
        echo "FAILURE: $skipped_count tests were skipped"
    elif [ "$failed_count" -gt 0 ]; then
        echo "FAILURE: $failed_count tests failed"
    elif [ "$passed_count" -eq 0 ]; then
        echo "FAILURE: No tests ran"
    else
        echo "FAILURE: Tests failed with exit code $exit_code"
    fi
    exit_code=1
fi

# Cleanup Snowflake clone (if applicable)
python3 /cleanup_snowflake.py || true

exit $exit_code
