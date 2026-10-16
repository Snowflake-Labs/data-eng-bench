# WIDE-Bench

WIDE-Bench measures how well coding agents do real dbt data-engineering work on a
large, realistic retail warehouse. Each task drops an agent into a containerized
dbt project with a ticket-style instruction and a hidden verifier; the agent
edits or creates dbt models, runs dbt, and is scored by a `pytest` verifier that
checks the materialized tables row by row against a reference solution. It runs
on [Harbor](https://www.harborframework.com/), so any Harbor-supported agent
(Claude Code, Codex, Cortex Code, Terminus, and others) is evaluated with one
command.

## Links

- Running with Cortex Code: [docs/cortex-code.md](docs/cortex-code.md) (credentials, benchmark-integrity notes, running without Harbor)

## The benchmark

The same 103 tasks run against either backend, selected at run time by the
`DB_TYPE` environment variable:

| Variant | `DB_TYPE` | Snowflake account | What it isolates |
|---|---|---|---|
| DuckDB (default) | `duckdb` | Not required (fully hermetic) | Whether the agent writes correct dbt SQL against a backend |
| Snowflake | `snowflake` | Required (free tier works) | Whether the agent also handles Snowflake dialect, warehouses, roles, and idioms |

## Getting started

Prerequisites: [uv](https://docs.astral.sh/uv/) and Docker. Install Harbor
(0.21.0 or newer — some flags below were renamed after 0.20.x) and prepare the
workspace:

```bash
uv tool install harbor
curl -fL -o base-image/database/retail.duckdb \
  https://huggingface.co/datasets/widebench/wide-bench-warehouse/resolve/main/retail.duckdb   # ~489 MB
cp .env.example .env         # then fill in the API key for your agent's model
docker build base-image/ -t wide-bench-base:1.0.0
```

## Running (DuckDB, no account)

The DuckDB variant is hermetic: `retail.duckdb` is baked into the base image, so
no Snowflake account and no network data access are needed.

```bash
# one task, to check your setup
harbor run --config configs/wide-bench-duckdb.claude-code.yaml --path tasks \
  -i dbt-fix-refund-reconciliation

# the full suite (k=3, all 103 tasks)
harbor run --config configs/wide-bench-duckdb.claude-code.yaml --path tasks
```

Swap the agent and model freely, or use the `codex` / `cortex-code` configs
(for `cortex-code`, see [docs/cortex-code.md](docs/cortex-code.md) first —
it needs extra credentials even on DuckDB, and a few flags below changed
between Harbor versions).

Run only the fast subset:

```bash
harbor run --config configs/wide-bench-duckdb.claude-code.yaml --path tasks \
  $(sed 's/^/-i /' configs/fast-30.txt)
```

A `k=3` sweep over all 103 DuckDB tasks is dominated by agent token cost and
finishes in a few hours at `n_concurrent_trials: 4`.

## Running (Snowflake)

The Snowflake variant runs the same 103 tasks against a real Snowflake account.

**1. Configure a connection.** Create `~/.snowflake/connections.toml` with a
connection named `dbt_bench`:

```toml
[dbt_bench]
account = "abcd-xy12345"      # your account identifier
user = "YOUR_USERNAME"
password = "YOUR_PASSWORD"     # or key-pair auth
warehouse = "COMPUTE_WH"
role = "SYSADMIN"
```

**2. Load the data (one time).** The benchmark data is a single DuckDB file,
`retail.duckdb`, baked into the base image. `migrate_duckdb.py` uploads every
schema and table into a Snowflake database named `DBT_BENCH_RETAIL`, which the
Snowflake tasks read from.

```bash
# extract retail.duckdb from the built image (or use the downloaded file directly)
id=$(docker create wide-bench-base:1.0.0)
docker cp "$id:/app/database/retail.duckdb" ./retail.duckdb
docker rm "$id"

pip install "snowflake-connector-python[pandas]" duckdb
python base-image/migrate_duckdb.py ./retail.duckdb
```

The script creates `DBT_BENCH_RETAIL`, recreates each schema, uploads each table
(mapping DuckDB types to Snowflake), and grants read access to `PUBLIC`. It
takes roughly 10 to 25 minutes on an XS warehouse and runs once; later runs
reuse the database. Flags: `--force` recreates the database, `--resume` skips
already-uploaded tables, and `SNOWFLAKE_CONNECTION_NAME=<name>` selects a
different connection.

**3. Run.** Export the connection as environment variables, then run:

```bash
export SNOWFLAKE_ACCOUNT=abcd-xy12345 SNOWFLAKE_USER=YOUR_USERNAME \
       SNOWFLAKE_PASSWORD=YOUR_PASSWORD SNOWFLAKE_WAREHOUSE=COMPUTE_WH \
       SNOWFLAKE_SOURCE_DATABASE=DBT_BENCH_RETAIL SNOWFLAKE_ROLE=SYSADMIN
harbor run --config configs/wide-bench-snowflake.claude-code.yaml --path tasks
```

Each task's Harbor healthcheck clones `SNOWFLAKE_SOURCE_DATABASE` into an
isolated `retail_clone_*` database and points the agent + verifier at it; the
role only needs `CREATE DATABASE` plus access to the source. The clone and
verifier accept password auth (above) or key-pair (`SNOWFLAKE_PRIVATE_KEY`,
base64 PEM). Note the bundled reference solutions (`solution/solve.sh`)
authenticate dbt with key-pair, so reproducing the oracle on
Snowflake requires `SNOWFLAKE_PRIVATE_KEY`.

Each task drops its clone at the end of the verifier phase. A run that fails
*before* verification (e.g. a clone timeout) can leave a `retail_clone_*`
behind, since Harbor tasks have no always-run teardown hook. Reclaim strays
with `base-image/sweep_snowflake_clones.py` (drops `retail_clone_*` older than
a `--older-than-hours` cutoff; supports `--dry-run`).

A `k=3` sweep over all 103 Snowflake tasks runs roughly 6 to 9 warehouse-hours
on a free-tier account; use the fast subset for cost-bounded runs.

## Benchmark integrity

Agents should not be able to look up reference solutions during a run. This
matters more now that the tasks and their reference solutions are public.

The bundled configs disable web tools where the agent supports it:

| Config | Web tools |
|---|---|
| `claude-code` | off &mdash; `disallowed_tools: WebSearch,WebFetch` |
| `codex` | off &mdash; `web_search: disabled` |
| `cortex-code` | off &mdash; `disallowed_tools: web_search web_fetch` (requires Harbor >= 0.22.0) |
| `terminus-2` (the commented fallback) | none exist |

Cortex Code keeps `web_search` and `web_fetch` available in every agent mode,
including code mode. Harbor's `cortex-code` agent only gained the option to
switch them off in [harbor#2787](https://github.com/harbor-framework/harbor/pull/2787),
which shipped in Harbor 0.22.0. On an older Harbor the kwarg is dropped
silently rather than rejected, so if you're not on 0.22.0+, isolate
`cortex-code` runs at the network layer instead (below).

For any agent, Harbor's network allowlist is the stricter control, and the only
one that does not depend on agent support:

```bash
harbor run ... --allow-agent-host <model-api-host>
```

The DuckDB variant needs only your model API host; the Snowflake variant also
needs `<account>.snowflakecomputing.com`. If you add a config for another agent,
disable its browsing tools too &mdash; and check that the setting took effect, since
an unrecognised kwarg is dropped silently rather than rejected.

## Tasks

All 103 WIDE-Bench tasks ship in `tasks/` (listed in `dataset.toml`), and
`configs/fast-30.txt` is a balanced 30-task subset. One task,
`dbt-fix-timezone-sales`, is timezone-sensitive and its DuckDB verifier can be
order-dependent; it is included for completeness, and its individual DuckDB
result should be read as advisory.

## License

Apache-2.0 (see [LICENSE](LICENSE) and [NOTICE](NOTICE)). The tasks, dbt models,
and synthetic `retail` dataset are original works.
