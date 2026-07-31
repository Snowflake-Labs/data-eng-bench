# dbt-bench

dbt-bench measures how well coding agents do real dbt data-engineering work on a
large, realistic retail warehouse. Each task drops an agent into a containerized
dbt project with a ticket-style instruction and a hidden verifier; the agent
edits or creates dbt models, runs dbt, and is scored by a `pytest` verifier that
checks the materialized tables row by row against a reference solution. It runs
on [Harbor](https://www.harborframework.com/), so any Harbor-supported agent
(Claude Code, Codex, Cortex Code, Terminus, and others) is evaluated with one
command.

The 103 tasks span four categories:

| Category | Tasks | What the agent does |
|---|---|---|
| **Analytics** | 65 | Build analytics marts: churn and retention cohorts, RFM segmentation, CLTV forecasting, fraud detection, marketing attribution, product-affinity and basket analysis, campaign ROI. |
| **Development and bug-fixes** | 16 | Diagnose and fix broken or incomplete dbt models (SQL errors, null handling, wrong logic) so the output matches the spec. |
| **Dimensional modeling and snapshots** | 9 | Author dimension and fact tables and dbt snapshots (slowly-changing-dimension history). |
| **Data engineering** | 13 | Build incremental models, multi-database and cross-warehouse pipelines, and other engineering-heavy transforms. |

Difficulty spread: 3 easy, 47 medium, 45 hard, 8 very hard.

## Links

- Dataset: `snowflake-labs/dbt-bench` on the [Harbor Hub](https://hub.harborframework.com/)
- Leaderboard: the public dbt-bench leaderboard on the Harbor Hub (see [Submitting to the leaderboard](#submitting-to-the-leaderboard))

## The benchmark

The same 103 tasks run against either backend, selected at run time by the
`DB_TYPE` environment variable:

| Variant | `DB_TYPE` | Snowflake account | What it isolates |
|---|---|---|---|
| DuckDB (default) | `duckdb` | Not required (fully hermetic) | Whether the agent writes correct dbt SQL against a backend |
| Snowflake | `snowflake` | Required (free tier works) | Whether the agent also handles Snowflake dialect, warehouses, roles, and idioms |

Running both and comparing is the point: a task that passes on DuckDB but fails
on Snowflake isolates a Snowflake-specific gap rather than a modeling error. A
balanced 30-task subset for quick or cost-bounded runs is listed in
`configs/fast-30.txt`.

## Getting started

Prerequisites: [uv](https://docs.astral.sh/uv/), Docker, and
[Git LFS](https://git-lfs.com/). Install Harbor (tested with 0.20.x) and prepare
the workspace:

```bash
uv tool install harbor
git lfs pull                 # materialize base-image/database/retail.duckdb (~489 MB)
cp .env.example .env         # then fill in the API key for your agent's model
docker build base-image/ -t dbt-bench-base
```

## Running (DuckDB, no account)

The DuckDB variant is hermetic: `retail.duckdb` is baked into the base image, so
no Snowflake account and no network data access are needed.

```bash
# one task, to check your setup
harbor run --path tasks --task-name dbt-fix-division-by-zero \
  --agent claude-code --model anthropic/claude-opus-4-8 --env DB_TYPE=duckdb

# the full suite (k=3, all 103 tasks)
harbor run --config configs/dbt-bench-duckdb.claude-code.yaml --path tasks
```

Swap the agent and model freely, or use the `codex` / `cortex-code` configs.
Once the dataset is on the Harbor Hub you can run it without a local checkout:

```bash
harbor run -d snowflake-labs/dbt-bench --agent claude-code --model anthropic/claude-opus-4-8
```

Run only the fast subset:

```bash
harbor run --config configs/dbt-bench-duckdb.claude-code.yaml --path tasks \
  $(sed 's/^/--task-name /' configs/fast-30.txt)
```

A `k=3` sweep over all 103 DuckDB tasks is dominated by agent token cost and
finishes in a few hours at `n_concurrent_trials: 4`.

## Running (Snowflake)

The Snowflake variant runs the same 103 tasks against a real Snowflake account.
No account yet? A free trial takes a couple of minutes:
https://signup.snowflake.com/cortex-code

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
# extract retail.duckdb from the built image (or use the file directly after `git lfs pull`)
id=$(docker create dbt-bench-base)
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
       SNOWFLAKE_DATABASE=DBT_BENCH_RETAIL SNOWFLAKE_ROLE=SYSADMIN
harbor run --config configs/dbt-bench-snowflake.claude-code.yaml --path tasks
```

A `k=3` sweep over all 103 Snowflake tasks runs roughly 6 to 9 warehouse-hours
on a free-tier account; use the fast subset for cost-bounded runs.

## Benchmark integrity

Agents should not be able to look up reference solutions during a run. The
bundled `claude-code` configs disable web tools
(`disallowed_tools: WebSearch,WebFetch`); disable the equivalent browsing tools
for other agents. For stricter isolation, run under Harbor's network allowlist
with `--allow-agent-host`: the DuckDB variant needs only your model API host,
and the Snowflake variant also needs `<account>.snowflakecomputing.com`.

## Submitting to the leaderboard

Run at least 3 trials per task, upload the results publicly, then open a
submission PR:

```bash
harbor run -d snowflake-labs/dbt-bench -a <agent> -m <provider/model> -k 3 --upload --public
cd leaderboard && uv run lb submit https://hub.harborframework.com/jobs/<uuid>
```

CI validates the submission and maintainers review the trajectories before it
merges as a new leaderboard row. See
[leaderboard/SUBMIT.md](leaderboard/SUBMIT.md) for details.

## Tasks

All 103 dbt-bench tasks ship in `tasks/` (listed in `dataset.toml`), and
`configs/fast-30.txt` is a balanced 30-task subset. One task,
`dbt-fix-timezone-sales`, is timezone-sensitive and its DuckDB verifier can be
order-dependent; it is included for completeness, and its individual DuckDB
result should be read as advisory.

## Citation

If you use dbt-bench, please cite this repository; see [CITATION.cff](CITATION.cff).

## License

Apache-2.0 (see [LICENSE](LICENSE) and [NOTICE](NOTICE)). The tasks, dbt models,
and synthetic `retail` dataset are original Snowflake works; the `leaderboard/`
tooling and CI are adapted from Harbor's Apache-2.0 Terminal-Bench 2.1 repo.
