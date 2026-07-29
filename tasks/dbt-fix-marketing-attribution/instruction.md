# Fix Broken Marketing Attribution Report (Hard Mode)

The marketing attribution report (`marts/marketing/rpt_attribution_BROKEN.sql`) has been broken since the GA4 migration on 2024-03-01. The model produces incorrect attribution metrics due to faulty UTM parsing logic and incorrect field references.

## Problem

The broken model has several issues:
1. **Incorrect UTM parsing**: Uses `SPLIT_PART` logic that doesn't work with GA4 data format
2. **Missing field references**: References fields that don't exist in the joined model
3. **Incorrect date field**: Uses `event_date` which doesn't exist
4. **Wrong conversion logic**: Uses `conversion_flag` instead of `is_converted`

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)
- Reference dbt project: `/app/dbt_models_duckdb`

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
- Reference dbt project: `/app/dbt_models_snowflake`

**Note**: For Snowflake, the entrypoint automatically creates a clone database and sets `SNOWFLAKE_DATABASE`. The clone is destroyed when the task completes.

## Data Environment

- **Source models** (already materialized in the reference dbt project):
  - `int_sessions_events_joined` - Joins sessions and events (has fanout: one session -> many events)
    - **Column naming**: Columns from the events table are prefixed with `t2_` (e.g., `t2_event_name`, `t2_event_value`, `t2_event_timestamp`)
    - **Key columns**: `session_id`, `t2_event_name`, `t2_event_value`, `t2_event_timestamp`
  - `stg_ga__sessions` - Sessions table with UTM parameters (`utm_source`, `utm_medium`, `utm_campaign`) and conversion flag (`is_converted`)
    - **Key columns**: `session_id`, `session_start`, `utm_source`, `utm_medium`, `utm_campaign`, `is_converted`
  - `stg_ga__events` - Events table with event-level data and timestamps

**Important (read carefully -- this task is intentionally tricky):**
- **Use `CAST(x AS DATE)` for date extraction**. `DATE(x)` may not be available in all backends.
- **Schema naming**: Due to dbt schema naming behavior, reference models often materialize under `main` (e.g., `main.stg_ga__sessions`). Your solution must be robust to this.
- **Conversion flag type**: `is_converted` may behave as a boolean or a numeric value depending on the backend. Use explicit casting when comparing.
- **Joined model field coverage**: `int_sessions_events_joined` may omit some event fields (and may omit `t2_event_value` entirely). If that happens, you must source revenue from `stg_ga__events.event_value` instead.
- Use `dbt ls` and direct SQL to verify what columns exist in this environment before finalizing your logic.

## dbt Profile Setup

- **Profile name**: `retail_dw_master`
- Create a `profiles.yml` in the dbt project directory
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Project Setup

- **Project location**: `/app/dbt_project`
- **Schema**:
  - DuckDB: `analytics`
  - Snowflake: `main` (the default schema of the clone database)

**Configuration Note**: Set the schema in `profiles.yml`. Do not add `+schema` in `dbt_project.yml`.

**Snowflake schema routing**: On Snowflake, models must land in the `main` schema (not `analytics`). To achieve this, override the `generate_schema_name` macro so that dbt places all models in the target schema defined in `profiles.yml` (i.e., `main`), ignoring any custom schema config. Create `macros/generate_schema_name.sql` with a macro that returns the default schema unconditionally.

## Task Requirements

### 1. Investigate the Broken Model

Examine `marts/marketing/rpt_attribution_BROKEN.sql` in the reference dbt project to understand:
- What fields are available in `int_sessions_events_joined`
- How UTM parameters are stored in GA4 format
- What conversion fields are available

### 2. Create Fixed Model

Create a new model `marts/marketing/rpt_attribution_fixed.sql` that:

- **Correctly extracts UTM parameters**:
  - `channel`: Extract from `utm_source` in `stg_ga__sessions` (GA4 stores this directly, no parsing needed)
  - `medium`: Extract from `utm_medium` in `stg_ga__sessions` (GA4 stores this directly)
  - `campaign`: Extract from `utm_campaign` in `stg_ga__sessions` (GA4 stores this directly)
  - Handle NULL values appropriately (use 'direct' for NULL utm_source, 'none' for NULL utm_medium/campaign)

- **Uses correct date field**:
  - Use `session_start` from sessions table (cast to date) for attribution date
  - Filter to last 90 days relative to the most recent session start date in the dataset (i.e., use a subquery to find MAX(CAST(session_start AS DATE)) from the sessions source, then keep rows within 90 days of that date)

- **Correctly calculates metrics**:
  - `sessions`: Count distinct session_id (handle fanout from join if using `int_sessions_events_joined`)
  - `conversions`: Count sessions where `is_converted` is truthy
  - `attributed_revenue`:
    - Prefer `t2_event_value` from `int_sessions_events_joined` if it exists in your environment
    - Otherwise use `event_value` from `stg_ga__events`
    - Only include purchase events (`event_name = 'purchase'` / `t2_event_name = 'purchase'`)
    - Only include events tied to converted sessions
    - Sum per session first to avoid fanout inflation, then aggregate into the final grain
  - `conversion_rate`: conversions / sessions (handle division by zero, round to 4 decimals)

- **Handles data quality**:
  - Filter out NULL session_ids
  - Handle missing UTM parameters gracefully
  - Ensure no duplicate sessions in aggregation

### 3. Output Schema

The model must produce the following columns:
- `attribution_date` (DATE) - Date of the session
- `channel` (VARCHAR) - Marketing channel (from utm_source)
- `medium` (VARCHAR) - Marketing medium (from utm_medium)
- `campaign` (VARCHAR) - Campaign name (from utm_campaign)
- `sessions` (INTEGER) - Count of distinct sessions
- `conversions` (INTEGER) - Count of converted sessions
- `attributed_revenue` (DECIMAL) - Total revenue attributed to these sessions
- `conversion_rate` (DECIMAL) - Conversion rate (conversions / sessions, rounded to 4 decimals)

### 4. Business Rules

1. **UTM Parameter Extraction**:
   - In GA4, UTM parameters are stored directly in the sessions table
   - No parsing/splitting is needed - use values as-is
   - If `utm_source` is NULL, set channel to 'direct'
   - If `utm_medium` is NULL, set medium to 'none'
   - If `utm_campaign` is NULL, set campaign to 'none'

2. **Session Counting**:
   - Count distinct `session_id` to avoid double-counting from join fanout
   - Only count sessions where `session_start` is not NULL

3. **Conversion Logic**:
   - A session is converted if `is_converted = 1` in the sessions table (`stg_ga__sessions`)
   - Revenue should come from events where conversion occurred
   - **Conversion events**: Events with `t2_event_name = 'purchase'` in `int_sessions_events_joined` represent conversion events
   - **Revenue field**: Use `t2_event_value` from `int_sessions_events_joined` for revenue (this is the event value column from the joined events table)
   - If `t2_event_value` is NULL, treat as 0

4. **Date Handling**:
   - Use `CAST(session_start AS DATE)` for attribution_date
   - Filter: `CAST(session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM <sessions_source>) - interval '90 days'`

## Output Requirements

The `rpt_attribution_fixed` model must:
1. Run successfully with `dbt run`
2. Produce correct attribution metrics
3. Have no NULL values in required columns (use appropriate defaults)
4. Have valid conversion rates (0.0 to 1.0)
5. Be internally consistent:
   - `conversions <= sessions` for every row
   - `conversion_rate` must equal `conversions/sessions` rounded to 4 decimals
   - Revenue must not be negative

## Technical Notes

- **Schema References**:
  - Reference models materialize under `main` in this environment (e.g., `main.stg_ga__sessions`).
  - On DuckDB, your output model must be in the `analytics` schema.
  - On Snowflake, your output model must be in the `main` schema. Use a `generate_schema_name` macro override to ensure dbt routes the model to `main` instead of appending a custom schema suffix.

- **Column Naming in int_sessions_events_joined**:
  - The `int_sessions_events_joined` model prefixes columns from the events table with `t2_`
  - Use `t2_event_name` for event names (e.g., 'purchase' for conversion events)
  - Use `t2_event_value` for event values (revenue) **if present in your environment**
  - Use `t2_event_timestamp` for event timestamps

- **Model Setup**:
  - Before creating your model, you may need to run the reference dbt project to materialize source models:
    - For DuckDB: `cd /app/dbt_models_duckdb && dbt deps && dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined`
    - For Snowflake: `cd /app/dbt_models_snowflake && dbt deps && dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined`

- **The `int_sessions_events_joined` model has a LEFT JOIN that creates fanout (one session -> many events)**
- **You must use `COUNT(DISTINCT session_id)` to avoid double-counting sessions**
- **UTM parameters are already clean in GA4 - no parsing needed**
- **The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)**
- **Ensure idempotent execution (multiple runs produce same results)**

## Exploration

You can explore the data using:
- `dbt ls` - List available models
- `dbt run --select int_sessions_events_joined` - Run the source model
- `dbt show --select int_sessions_events_joined --limit 10` - Preview data
- Direct SQL queries against the database to understand the schema

## Guidelines
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use `CAST(... AS DATE)` instead of `DATE(...)` function
- Use `DATEDIFF` for date differences
- Use `COALESCE` for NULL handling
- Use `NULLIF` to protect against division by zero
