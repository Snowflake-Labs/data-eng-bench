# dbt: Debug Customer Snapshot and Build Dimension Model

## Objective

Fix a dbt snapshot model that is producing incorrect results, then build a downstream dimension model that derives analytical attributes from the corrected snapshot.

## Background

The analytics team has reported data quality issues with the customer snapshot output. The snapshot is supposed to implement SCD Type 2 tracking for customer data, but multiple problems have been identified. The issues affect both the snapshot configuration and the data completeness of the output.

Additionally, the team needs a **`dim_customer_current`** model that provides a single-row-per-customer view with useful analytical columns derived from the snapshot history. This model must be built as a standard dbt model (not a snapshot) that reads from the corrected snapshot.

## Part 1: Fix the Customer Snapshot

Investigate the customer snapshot model to identify **all** problems. The model has data quality issues -- examine both the model configuration and the data it produces to find everything that is wrong. There may be more than one issue.

- DuckDB: `/app/dbt_models_duckdb/snapshots/customer_snapshot.sql`
- Snowflake: `/app/dbt_models_snowflake/snapshots/customer_snapshot.sql`

## Part 2: Create `dim_customer_current` Model

After fixing and running the snapshot, create a new dbt model called **`dim_customer_current`** that reads from the `customer_snapshot` snapshot and produces a single-row-per-customer analytical table. This model must be placed in the dbt project's `models/` directory.

The model must include **all columns from the current snapshot record** plus the following derived columns:

1. **`days_since_last_update`** -- The number of days between `dbt_valid_from` and the current date, computed only for the current record (where `dbt_valid_to IS NULL`). Use `DATEDIFF` (Snowflake) or date subtraction (DuckDB), or write Jinja that works for both backends.

2. **`total_versions`** -- The total count of snapshot versions (rows) that exist for each customer across all history. This requires aggregating over the full snapshot table grouped by `customer_id`.

3. **`is_recently_changed`** -- A boolean column that is `true` when the customer's current record was created (i.e., `dbt_valid_from`) within the last 30 days, and `false` otherwise.

The model should only include **current** records (where `dbt_valid_to IS NULL`) and must produce exactly one row per `customer_id`. Run `dbt run` to materialize this model after the snapshot completes.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)

### Snowflake
- Set `DB_TYPE=snowflake`
- Environment variables (pre-configured):
  - `SNOWFLAKE_ACCOUNT`
  - `SNOWFLAKE_USER`
  - `SNOWFLAKE_PASSWORD`
  - `SNOWFLAKE_DATABASE` - The clone database to use
  - `SNOWFLAKE_SCHEMA`
  - `SNOWFLAKE_WAREHOUSE`
  - `SNOWFLAKE_ROLE` (optional)

**Note**: For Snowflake, the entrypoint automatically creates a clone database and sets `SNOWFLAKE_DATABASE`. The clone is destroyed when the task completes.

## Data Sources

- **stg_customers** (in `main` schema) - Contains customer data
- **customer_snapshot** (in `snapshots` schema) - The SCD Type 2 snapshot you fix in Part 1

## Success Criteria

1. All tests pass
2. The snapshot correctly tracks all customers from the source
3. The `dim_customer_current` model exists with correct columns and data
4. Exactly one row per customer in `dim_customer_current`
5. All derived columns compute correctly (non-negative days, positive version counts, consistent boolean logic)

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role
- Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank. A blank or omitted schema makes Snowflake silently default to `PUBLIC`, so your models get built in the wrong schema and the verifier cannot find them.
