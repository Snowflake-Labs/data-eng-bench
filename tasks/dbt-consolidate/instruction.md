# High-level Task Instruction

The task is to consolidate staging data into an intermediate layer through standardization and union.

You are given multiple ads datasets. The task is to load these datasets into dbt. Implement a staging view on top of it. Finally, write a model in the intermediate layer that unions all these staging views.

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

## Data

These CSV files are provided in `/app/data`:
- `googleads.csv`
- `metaads.csv`
- `tiktokads.csv`

Load this data using `dbt seed`

### CSV schema
- `googleads.csv`: `ad_date, clicks, impressions, views, conversions`
- `metaads.csv`: `ad_date, clicks, impressions, views_1, views_2, conversions`
- `tiktokads.csv`: `ad_date, clicks, impressions, views_1, conversions`

## Packages

Install `dbt-utils` package and run `dbt deps` in the project directory.

## dbt Profile Setup

Create a dbt project at `/app/dbt_consolidate` with profiles in the project directory. The `name:` field in `dbt_project.yml` **must be set to `dbt_consolidate`** exactly.

- Profile Name: `retail_dw_master`
- Schema: `analytics`

### DuckDB Profile
Configure with `type: duckdb` and database path `/app/consolidate.duckdb`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

Set `DBT_PROFILES_DIR` to the project directory.

## Required Models

**Staging layer** (`models/staging/`):
The staging views must be prefixed with `stg__ads_` for ads data.
Clean the data using simple SQL using following instructions:
1. Combine multiple columns having `views` in their names into a single column `views`.
2. Dedupe using `qualify` clause. Use a window function to identify and remove duplicate rows. Group rows that have identical content and keep only one per group.

Note the names of the staging views:
- `stg__ads_googleads.sql` - cleaned google ads data
- `stg__ads_metaads.sql` - cleaned meta ads data
- `stg__ads_tiktokads.sql` - cleaned tiktok ads data

Standardize all staging outputs to:
`ad_date, clicks, impressions, views, conversions`

Column combination rules:
- `googleads.csv`: use `views` as-is.
- `metaads.csv`: `views = views_1 + views_2`.
- `tiktokads.csv`: `views = views_1`.

**Intermediate layer** (`models/int/`):
Follow these rules for generating Intermediate Table `int__ads_unified.sql`:
1. Use union all SQL clause to combine the ads data into a single int model materialized as table.
2. During union hardcode `source` column for every ads data that goes into table
    - source is the name of the ads platform

Required `source` values:
- `google`
- `meta`
- `tiktok`

**Additional Instructions**
Create a yaml file for `staging` and `int` models named `staging.yml` and `int.yml`.
For the `int__ads_unified.sql`, add `dbt_utils.unique_combination_of_columns` test for the combination of `ad_date` and `source` using dbt utils package.

Verify the pipeline with `dbt test` command.

## Guidelines
- Use `qualify` clause for deduplication (supported by both DuckDB and Snowflake)
- Use `row_number()` window function for deduplication
