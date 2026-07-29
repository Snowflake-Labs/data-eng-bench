# Email Attribution Report Fix

## Context

You are an analytics engineer tasked with rebuilding a broken email attribution reporting model. The original model failed due to upstream schema changes in the GA4 data pipeline. Your goal is to create a robust, production-ready dbt model that accurately tracks email marketing performance.

## Objective

Build a dbt model `rpt_email_attribution_fixed.sql` that generates a daily attribution report for email marketing campaigns. The model must be placed in `/app/dbt_project/models/marts/marketing/` and materialize to the `analytics` schema.

## Output Schema

The final table `analytics.rpt_email_attribution_fixed` must contain exactly these columns:

| Column | Type | Description |
|--------|------|-------------|
| `attribution_date` | DATE | Date of the session (from session_start) |
| `channel` | VARCHAR | Marketing channel (utm_source, default: 'direct') |
| `medium` | VARCHAR | Marketing medium (utm_medium, default: 'none') |
| `campaign` | VARCHAR | Campaign name (utm_campaign, default: 'none') |
| `sessions` | BIGINT | Count of distinct sessions |
| `conversions` | BIGINT | Count of sessions that converted |
| `attributed_revenue` | DECIMAL(12,2) | Total revenue attributed to these sessions |
| `conversion_rate` | DECIMAL(10,4) | Conversion rate (conversions/sessions), between 0 and 1 |

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
- Create a `profiles.yml` in the dbt project directory with profile name `dbt_project`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Business Rules

### Data Source
- Primary source: `main.stg_ga__sessions` table
- Revenue source: Prefer `main.int_sessions_events_joined` if available (check for `t2_event_value` column), otherwise fall back to `main.stg_ga__events`
- Reference models: Run `dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined` first
- DuckDB: `/app/dbt_transforms/`
- Snowflake: `/app/dbt_models_snowflake/`

### Time Filtering
- Include only sessions where `session_start` date is on or after 2025-10-04 (fixed cutoff)
- Use `CAST(session_start AS DATE) >= DATE '2025-10-04'`
- Exclude sessions after the data generation date: `CAST(session_start AS DATE) <= DATE '2026-01-02'`

### UTM Parameter Normalization
- `channel`: Use `utm_source`, if NULL or empty string, default to `'direct'`
- `medium`: Use `utm_medium`, if NULL or empty string, default to `'none'`
- `campaign`: Use `utm_campaign`, if NULL or empty string, default to `'none'`
- Always trim whitespace before checking for empty strings
- Handle both NULL and empty string cases explicitly

### Session Counting
- Count distinct `session_id` values
- Filter out NULL or empty `session_id` values
- Group by: `attribution_date`, `channel`, `medium`, `campaign`
- Each combination should appear exactly once

### Conversion Logic
- A session is converted if `is_converted = true`
- Handle various boolean representations: `true`, `'1'`, `'true'`, `1`, etc.
- Count distinct converted sessions per dimension combination
- Conversions must never exceed sessions for any row

### Revenue Attribution
- Only attribute revenue to converted sessions (`is_converted = true`)
- Sum `event_value` from purchase events (`event_name = 'purchase'`)
- If using `int_sessions_events_joined`, use `t2_event_value` and `t2_event_name`
- Round revenue to 2 decimal places: `ROUND(..., 2)`
- Ensure non-negative values (use `GREATEST(..., 0)`)

### Conversion Rate Calculation
- Formula: `conversions / sessions`
- Round to 4 decimal places: `ROUND(..., 4)`
- If `sessions = 0`, set `conversion_rate = 0.0`
- Must be between 0.0 and 1.0 (inclusive)
- Cast to `DECIMAL(10,4)` for precision

## Implementation Requirements

### Project Structure
```
/app/dbt_project/
├── dbt_project.yml
└── models/
    └── marts/
        └── marketing/
            └── rpt_email_attribution_fixed.sql
```

### dbt Configuration
- Profile name: `dbt_project`
- Target schema: `analytics`
- Materialization: `table`

### Code Quality
- Use CTEs for clarity and maintainability
- Handle edge cases (NULLs, empty strings, type coercion)
- Use `adapter.get_relation()` to check table availability
- Use `adapter.get_columns_in_relation()` to check for specific columns
- Add proper error handling for missing relations

### Performance Considerations
- Use `DISTINCT` appropriately to avoid duplicates
- Filter early in CTEs to reduce data volume
- Use proper JOINs (LEFT JOIN for optional revenue data)
- Consider using `HAVING` clause to filter out zero-session rows

## Testing Requirements

The solution must pass all 10 test cases that validate:
1. Model compilation and table creation
2. Required columns and data types
3. Date range constraints (90 days)
4. UTM parameter normalization
5. Conversion rate calculation accuracy
6. Revenue handling and precision
7. Session aggregation correctness
8. Data quality and integrity
9. Email channel presence
10. Conversion count accuracy

## Guidelines
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Do NOT modify upstream staging models
- Do NOT change model materialization

## Tips

1. **Start with reference models**: Always run the reference dbt project first to ensure source tables exist
2. **Test incrementally**: Build and test each CTE separately if possible
3. **Handle NULLs explicitly**: Use `COALESCE` and `CASE` statements for robust NULL handling
4. **Type casting**: Explicitly cast types to match expected schema (DATE, BIGINT, DECIMAL)
5. **Precision matters**: Use exact precision for DECIMAL types (12,2) and (10,4)
6. **Boolean handling**: Convert various boolean representations to consistent true/false
7. **Revenue fallback**: Check for joined table first, then fall back to events table
8. **Empty result handling**: Ensure CTEs return proper structure even when empty (use `WHERE 1=0` pattern)

## Common Pitfalls to Avoid

- Forgetting to handle empty strings (not just NULLs)
- Incorrect date filtering (including future dates or dates older than 90 days)
- Double-counting sessions across dimension combinations
- Incorrect precision for revenue (should be 2 decimals) or conversion rate (should be 4 decimals)
- Not handling the case where sessions = 0 (conversion_rate should be 0.0)
- Missing revenue data when joined table doesn't exist
- Incorrect boolean conversion logic
