# Fix Multi-Touch Attribution Report

## Context

You are an analytics engineer rebuilding a multi-touch marketing attribution mart. The warehouse contains GA4-style sessions/events data and a reference dbt project. Create a new dbt model that outputs daily attribution metrics for **five attribution models**, **channel grouping**, and **assist metrics**.

## Environment

- **DuckDB database**: `/app/database/retail.duckdb`
- **DuckDB dbt project**: `/app/dbt_models_duckdb`
- **Snowflake dbt project**: `/app/dbt_models_snowflake`
- Create the project under `/app/dbt_project` with schema `analytics`.

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

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Objective

Create `rpt_multi_touch_attribution_fixed.sql` in `/app/dbt_project/models/marts/marketing/` that materializes `analytics.rpt_multi_touch_attribution_fixed`.

## Output Schema

| Column | Type | Description |
|--------|------|-------------|
| `attribution_date` | DATE | Session date (from session_start) |
| `channel` | STRING | utm_source, default `direct` |
| `medium` | STRING | utm_medium, default `none` |
| `campaign` | STRING | utm_campaign, default `none` |
| `channel_group` | STRING | One of: `Direct`, `Paid`, `Organic`, `Referral` |
| `attribution_model` | STRING | One of: `last_touch`, `first_touch`, `linear`, `time_decay`, `position_based` |
| `sessions` | INTEGER | Distinct session_id count |
| `conversions` | INTEGER | Sessions where is_converted = true |
| `attributed_revenue` | NUMERIC(12,2) | Sum purchase revenue for converted sessions |
| `conversion_rate` | NUMERIC | conversions/sessions, in [0,1], 4 decimals; 0 when sessions=0 |
| `assist_sessions` | INTEGER | Count of distinct sessions that are assists (see Business Rules) |

## Source Tables

- **main.stg_ga__sessions**: `session_id`, `visitor_id`, `customer_id`, `session_start`, `is_converted`, `utm_source`, `utm_medium`, `utm_campaign`
- **main.stg_ga__events**: `event_name`, `event_value`
- **main.int_sessions_events_joined** (optional): `t2_event_name`, `t2_event_value` -- prefer for revenue when available

Use `adapter.get_relation` / `adapter.get_columns_in_relation` to detect `int_sessions_events_joined` and `t2_event_value`.

## Business Rules

### Time window (deterministic)
- **Fixed 91-day window**: `CAST(session_start AS DATE) BETWEEN '2025-10-02'::DATE AND '2025-12-31'::DATE` (inclusive). Do not use `CURRENT_DATE` or `INTERVAL`.

### UTM and channel_group
- `channel`: `COALESCE(utm_source, 'direct')` (treat missing as `direct`)
- `medium`: `COALESCE(utm_medium, 'none')`; `campaign`: `COALESCE(utm_campaign, 'none')`
- **channel_group** (use `LOWER(TRIM(COALESCE(...,'')))` for comparisons):
  - `Paid`: `LOWER(TRIM(COALESCE(utm_medium,'')))` IN (`cpc`,`ppc`,`paid`,`cpm`)
  - `Organic`: `LOWER(TRIM(COALESCE(utm_medium,'')))` = `organic`
  - `Direct`: `LOWER(TRIM(COALESCE(utm_source,'')))` IN (`''`,`direct`) AND `LOWER(TRIM(COALESCE(utm_medium,'')))` IN (`''`,`none`,`(none)`)
  - `Referral`: else

### Sessions, conversions, revenue
- **Sessions**: `COUNT(DISTINCT session_id)`
- **Conversions**: sessions where `is_converted = true`
- **Attributed revenue**: sum of purchase `event_value` (or `t2_event_value` from `int_sessions_events_joined` if available) for converted sessions; round to 2 decimals
- **Conversion rate**: `conversions / sessions` rounded to 4 decimals; 0 when sessions=0; must be in [0,1]

### User identification
- Use `visitor_id`; if NULL, use `session_id` as fallback: `COALESCE(visitor_id, session_id)`

### assist_sessions
For each (attribution_date, channel, medium, campaign): count distinct `session_id` where that session is in at least one **converting path** and is **not the last touch** of that path.

- **Converting path** for a converted session C: all sessions (same `visitor_id`) with `session_start <= C.session_start` within the window. The last touch is C. All other touches are assists.
- A session that converts can be an assist for a *later* conversion by the same user.

### Attribution models

- **last_touch**: attribute conversions/revenue to the session's own channel/medium/campaign.
- **first_touch**: attribute to the earliest session per user (by `session_start`) in the window. All of that user's conversions and revenue go to the first session's channel/medium/campaign.
- **linear**: spread evenly across the user's sessions in the window. For N sessions, each gets 1/N of the user's conversions and revenue.
- **time_decay**: For each converting session C, build the path (same `visitor_id`, `session_start <= C.session_start`). For each touch: `days_before_conversion` = (C's session_start date - touch's session_start date) in days. Weight = `POW(2, -days_before_conversion / 7.0)` (7-day half-life). Normalize weights to sum 1 per path; attribute that conversion and its revenue in proportion. When days_before_conversion=0, weight=1.
- **position_based** (U-shaped): For each path, order by `session_start` (1=first, N=last). N=1 -> 100% to the only touch; N=2 -> 50% each; N>=3 -> 40% first, 40% last, 20% split evenly among the (N-2) middle touches: each middle gets `20/(N-2)`.

## Implementation Requirements

- Path: `/app/dbt_project/models/marts/marketing/rpt_multi_touch_attribution_fixed.sql`
- `dbt run --select rpt_multi_touch_attribution_fixed` must succeed and create `analytics.rpt_multi_touch_attribution_fixed`.
- Output must have rows for each of the five `attribution_model` values.
- Each row must include `channel_group` and `assist_sessions`.

## Tips

- Run reference models first: `dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined` in the dbt project directory (DuckDB: `/app/dbt_models_duckdb`, Snowflake: `/app/dbt_models_snowflake`).
- Prefer relations in the `main` schema for staged data.
- Round revenue to 2 decimals and conversion_rate to 4 decimals.

## Guidelines

- For date arithmetic, use `DATEDIFF('day', start, end)` which works on both backends
- Avoid DuckDB-specific syntax like `::DATE` casts or date subtraction operators
