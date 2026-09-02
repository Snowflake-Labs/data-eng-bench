# Running data-eng-bench with Cortex Code

Notes specific to running this benchmark with
[Cortex Code](https://signup.snowflake.com/cortex-code), plus a set of Harbor
gotchas that hit first-time runs regardless of agent. For the base setup
(installing Harbor, building the image, the DuckDB/Snowflake variants), see
the main [README](../README.md) — this page only covers what's different or
missing there.

Verified against Harbor 0.22.0 and Cortex Code v1.1.66. Re-check the commands
below if either has moved on since.

---

## Read this first

Several commands you'll find in older examples (including, at points, this
repo's own README) were written against Harbor 0.20.x and fail on current
Harbor. These account for nearly every first-run failure.

| Trap | Instead |
|---|---|
| **Harbor 0.20.x has no `cortex-code` agent.** It landed after the 0.20.0 release. | Require **harbor >= 0.21.0**. Check `harbor --version`. |
| **`disallowed_tools` / `cli_mode` are silently ignored below 0.22.0.** The agent exists on 0.21.0, but those two kwargs landed later ([harbor#2787](https://github.com/harbor-framework/harbor/pull/2787), [#2774](https://github.com/harbor-framework/harbor/pull/2774)) and an unrecognized kwarg is dropped, not rejected — see [Keeping results honest](#keeping-results-honest). | Require **harbor >= 0.22.0** if you use either. |
| **`--task-name` does not exist.** Harbor exits with "No such option". | **`-i`** / `--include-task-name` (accepts globs). |
| **`--env DB_TYPE=duckdb` fails.** `--env`/`-e` selects the environment *type* (docker, modal, …), not variables. | Use a shipped **`--config`**, which sets `environment.env` for you. |
| **Cortex Code needs Snowflake credentials even on DuckDB.** The DuckDB variant is hermetic for the *data*, but the agent still authenticates to Snowflake to reach its models. Without them the run dies immediately. | **`--ae SNOWFLAKE_ACCOUNT=… --ae SNOWFLAKE_USER=… --ae SNOWFLAKE_PAT=…`** |
| **`-m` / `--model` is silently ignored** when the config's agent block sets `model_name` — you keep the config's model and never hear about it. | Edit `model_name:` in the YAML (or copy the config per model). |
| **A bad credential fails silently.** Every trial ends in one turn with zero tokens, which reads as a model collapse rather than an auth error. | Curl the endpoint before a long run; see [Troubleshooting](#troubleshooting) below. |
| **`reasoning_effort` does nothing** for `cortex-code`. The shipped config sets it and `--ak` accepts it, but the adapter has no such option and drops it. | Ignore it. Don't read results as effort-controlled. |

Scoring is **all-or-nothing per task**: the verifier writes `1` to
`/logs/verifier/reward.txt` only if every test passes. A skipped test counts as
a failure.

---

## Running Cortex Code

Follow the README's [Getting started](../README.md#getting-started) to
install Harbor, build the base image, and set up `.env`. Then export
credentials for Cortex Code's own model access — separate from any Snowflake
credentials the *tasks* need, and required even on the DuckDB variant (see the
trap table above):

```bash
export SNOWFLAKE_ACCOUNT=abcd-xy12345
export SNOWFLAKE_USER=YOUR_USER
export SNOWFLAKE_PAT=<programmatic-access-token>   # or a password
```

Score one task, then scale up, using `-i`/`--include-task-name` rather than
the retired `--task-name`:

```bash
harbor run --config configs/data-eng-bench-duckdb.cortex-code.yaml --path tasks \
  -i dbt-fix-division-by-zero \
  --n-attempts 1 \
  --ae SNOWFLAKE_ACCOUNT="$SNOWFLAKE_ACCOUNT" \
  --ae SNOWFLAKE_USER="$SNOWFLAKE_USER" \
  --ae SNOWFLAKE_PAT="$SNOWFLAKE_PAT"

# 30-task subset — good for cost-bounded runs and CI
harbor run --config configs/data-eng-bench-duckdb.cortex-code.yaml --path tasks \
  $(sed 's|^|-i |' configs/fast-30.txt) \
  --ae SNOWFLAKE_ACCOUNT="$SNOWFLAKE_ACCOUNT" \
  --ae SNOWFLAKE_USER="$SNOWFLAKE_USER" \
  --ae SNOWFLAKE_PAT="$SNOWFLAKE_PAT"

# all 103 tasks, at the config's k=3
harbor run --config configs/data-eng-bench-duckdb.cortex-code.yaml --path tasks \
  --ae SNOWFLAKE_ACCOUNT="$SNOWFLAKE_ACCOUNT" \
  --ae SNOWFLAKE_USER="$SNOWFLAKE_USER" \
  --ae SNOWFLAKE_PAT="$SNOWFLAKE_PAT"
```

> **Comparing models?** Copy the config once per model and edit `model_name:`.
> Passing `-m` alongside `--config` will not change the model. Any `provider/`
> prefix is stripped before reaching the CLI, so `anthropic/claude-opus-4-8`
> and `claude-opus-4-8` behave identically.

For the Snowflake variant, follow the README's
[Running (Snowflake)](../README.md#running-snowflake) section for the data
load and dbt credentials, then add the same `--ae SNOWFLAKE_*` flags above to
`configs/data-eng-bench-snowflake.cortex-code.yaml`. The `--ae` credentials
authenticate the *agent*; the exported `SNOWFLAKE_*` variables from the README
configure the *container and verifier*. Both are needed.

### Keeping results honest

The tasks and their reference solutions are public, so agents shouldn't be
able to look up a reference solution mid-run. Cortex Code keeps `web_search`
and `web_fetch` available in **every** agent mode, including code mode, so
they have to be switched off explicitly — unlike `claude-code`, whose bundled
config already disables web tools via `disallowed_tools`.

Harbor's `cortex-code` agent supports this via `disallowed_tools`, added in
Harbor 0.22.0:

```yaml
agent:
  name: cortex-code
  kwargs:
    disallowed_tools: web_search web_fetch
```

Require **harbor >= 0.22.0** for this to take effect. On an older release,
Harbor drops an unrecognized kwarg **silently**, so the config reads as
protected while web access stays on — if you're stuck below 0.22.0, rely on
the network allowlist below instead.

Space-separated, not comma-separated, if you pass this as a string on the raw
CLI — the flag parses as an array and nothing splits on commas there, so
`web_search,web_fetch` would arrive as one pattern matching no tool.

The network allowlist is the stricter control and the only one that doesn't
depend on agent support:

```bash
harbor run ... --allow-agent-host <account>.snowflakecomputing.com
```

---

## Without Harbor

Every task is a plain Docker image plus a shell script that writes a reward
file, so you can run one by hand. This is the better path if you mainly want
to *watch* an agent work a realistic dbt ticket rather than produce a
benchmark number.

- **Option A** — Docker plus the verifier. Full control, no framework.
- **Option B** — Cortex Code inside the task container, interactive or
  headless.
- **Option C** — Harbor's `terminus-2`. Stuck on Harbor 0.20.x? The shipped
  `cortex-code` configs carry a commented `terminus-2` agent block as a
  portable fallback. Same tasks and verifiers.

### Option A — one task, by hand

Harbor normally mounts the task's `tests/` at `/tests` and the logs directory
at `/logs/verifier`. Do the same yourself. The instruction and reference
solution are **not** baked into the image, so mount those too.

```bash
T=dbt-fix-division-by-zero
docker build -t deb-$T tasks/$T/environment/
mkdir -p /tmp/$T/logs

docker run -d --name $T -e DB_TYPE=duckdb \
  -v "$PWD/tasks/$T/tests:/tests:ro" \
  -v "$PWD/tasks/$T/solution:/solution:ro" \
  -v "$PWD/tasks/$T/instruction.md:/instruction.md:ro" \
  -v "/tmp/$T/logs:/logs/verifier" \
  deb-$T sh -c 'sleep infinity'

cat tasks/$T/instruction.md          # the ticket — this is the prompt
docker exec -it $T bash              # edit the dbt project, run dbt

docker exec $T bash /tests/test.sh   # grade it
cat /tmp/$T/logs/reward.txt          # 1 = pass, 0 = fail
```

> **Sanity-check the loop first.** Run `docker exec $T bash /solution/solve.sh`
> before touching anything and confirm the reward is `1`. If the reference
> solution doesn't score, the problem is your harness, not the agent.

### Option B — Cortex Code in the container

The container has no `cortex` binary. Install it with the official script,
the same one Harbor's agent uses:

```bash
docker exec -it $T sh -c '
  curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh -o /tmp/i.sh
  NON_INTERACTIVE=1 sh /tmp/i.sh'

docker exec -it $T sh -c '
  export PATH="$HOME/.local/bin:$PATH"
  cortex --print "$(cat /instruction.md)" \
    --dangerously-allow-all-tool-calls --auto-accept-plans \
    --output-format stream-json --model <model>'
```

Cortex Code needs its own Snowflake connection inside the container — either
mount a `config.toml` at `~/.snowflake/` or pass `SNOWFLAKE_*` into `docker
run` and write one. Add `--mode code` if your build supports it (see
[Code mode](#code-mode) below).

### What you give up

- **Repeat-trial statistics.** No `k=3` / pass-at-k aggregation; these tasks
  are variable enough that a single trial per task is close to noise.
- **Parallelism.** Harbor runs many trials concurrently; by hand you get one.
- **The Snowflake healthcheck.** Per-task database cloning and cleanup won't
  run, so Snowflake trials will collide on shared state.
- **Trajectory capture and token accounting**, and therefore any leaderboard
  submission.
- **Network isolation** via the agent host allowlist.

---

## Code mode

Cortex Code's `--mode code` narrows the agent to a file-and-shell tool
surface, dropping the Snowflake data suite, teams, cron, goals, and MCP tools.
On a dbt benchmark that is a meaningfully different configuration to measure.

**Requires Harbor >= 0.22.0.** Harbor's `cortex-code` agent gained `cli_mode`
in that release:

```yaml
kwargs:
  cli_mode: code
```

Same version floor as `disallowed_tools` above — on an older release it's
silently ignored. The CLI flag itself works in headless runs, so Option B
above can use `--mode code` today regardless of Harbor version.

Note code mode does **not** remove `web_search` / `web_fetch` — it drops the
Snowflake data suite, teams, cron, goals, and MCP tools, but keeps both web
tools. It is not a substitute for `disallowed_tools`.

---

## Troubleshooting

**Every trial fails with zero tokens.** A wrong or expired model credential
does not surface as a clean authentication error — the symptom is that every
trial "completes" almost instantly with one turn and zero tokens recorded,
which reads like a model regression rather than a credential problem. Check
the credential before re-running anything. For an Anthropic-Messages-API
endpoint (used by `claude-code`, or by Cortex Code through a gateway):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-opus-4-8","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
  "$ANTHROPIC_BASE_URL/v1/messages"
```

`200` means the credential and endpoint are good. `401` means the token needs
refreshing — some short-lived tokens expire partway through a long sweep.
