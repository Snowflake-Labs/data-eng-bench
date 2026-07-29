#!/bin/bash
# Download this trial's trajectory + original task at runtime (TRIAL_ID and
# TASK_REF from the compose file, HARBOR_API_KEY from `harbor run --env-file`).
# The healthcheck waits for /app/trajectory.json and /app/task/instruction.md
# before the judge agent starts. Then hold the container open. Only trials that
# have a trajectory are ever sent here.
set -euo pipefail
: "${TRIAL_ID:?TRIAL_ID not set}"
: "${TASK_REF:?TASK_REF not set}"

harbor hub trial download "$TRIAL_ID" --trajectory -o /tmp/dl
cp /tmp/dl/*/trajectory.json /app/trajectory.json
rm -rf /tmp/dl

# TASK_REF is name@ref, baked in at gen_analysis_tasks time.
harbor download "$TASK_REF" -o /tmp/task_dl --overwrite
# Export layout for a single task: <output-dir>/<short-name>/
src=$(find /tmp/task_dl -mindepth 1 -maxdepth 1 -type d | head -1)
: "${src:?downloaded task directory not found}"
rm -rf /app/task
cp -a "$src" /app/task
rm -rf /tmp/task_dl

exec sleep infinity
