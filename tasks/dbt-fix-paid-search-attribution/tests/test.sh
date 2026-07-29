#!/bin/bash

# Source Snowflake env vars if available
if [ -f /tmp/snowflake_env.sh ]; then
    source /tmp/snowflake_env.sh
fi

mkdir -p /logs/verifier

# Run pytest and capture output
pytest /tests/test_outputs.py -v -rA 2>&1 | tee /logs/verifier/test-stdout.txt
exit_code=${PIPESTATUS[0]}

if [ $exit_code -eq 0 ]; then
    echo 1 > /logs/verifier/reward.txt
    echo "SUCCESS: All tests passed"
else
    echo 0 > /logs/verifier/reward.txt
    echo "FAILURE: Tests failed with exit code $exit_code"
fi

# Cleanup Snowflake clone (if applicable)
python3 /cleanup_snowflake.py || true

exit $exit_code
