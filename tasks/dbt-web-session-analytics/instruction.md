# Web Session Analytics Platform

The Digital Marketing team needs a comprehensive session analytics platform. Build models that score sessions, analyze visitor behavior patterns, and generate actionable insights.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Reference dbt projects exist at `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` for inspection only. Write your dbt project at `/app/dbt_project` — outputs in the reference directories are not graded.

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

## Data Environment

- **Project location**: Create a new standalone dbt project at `/app/dbt_project` (do not use any existing dbt project)
- **Schema**: `web_analytics`

Configure schema only in `profiles.yml`.

(Hint: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.)

## Source Data

Explore the `main` schema to find tables containing web session and pageview data. You will need to identify the relevant tables and understand their structure to build the analytics models.

## Required Models

### 1. fct_session_quality

Session-level quality scoring with these columns:

| Column | Description |
|--------|-------------|
| `session_id` | Session identifier |
| `visitor_id` | Visitor identifier |
| `session_start` | Session start timestamp |
| `duration_seconds` | Session duration |
| `page_views` | Number of pages viewed |
| `is_bounce` | TRUE if page_views = 1 |
| `is_converted` | Whether session converted |
| `device_type` | Device used |
| `engagement_score` | 1-5 score based on page_views quintile |
| `duration_score` | 1-5 score based on duration quintile |
| `quality_tier` | Premium/High/Medium/Low based on scores |
| `engagement_velocity` | page_views per minute (0 if duration < 60 seconds) |
| `velocity_category` | 'Fast' if velocity > 2, 'Normal' if 1-2, 'Slow' if < 1 and duration >= 60, NULL otherwise |
| `visit_number` | Nth visit by this visitor (ordered by session_start) |
| `is_returning_visitor` | TRUE if visit_number > 1 |

**Scoring Rules:**
- Use NTILE(5) with `session_id` as tiebreaker for deterministic ordering
- Quality tiers: Premium (both scores >= 4), High (either >= 4), Medium (both >= 2), Low (rest)

### 2. rpt_session_summary

Device-level aggregations:

| Column | Description |
|--------|-------------|
| `device_type` | Device type |
| `total_sessions` | Count of sessions |
| `total_conversions` | Count of conversions |
| `conversion_rate` | Ratio (4 decimal places) |
| `avg_duration` | Average duration (2 decimal places) |
| `avg_page_views` | Average page views (2 decimal places) |
| `bounce_rate` | Bounce ratio (4 decimal places) |
| `premium_sessions` | Count of Premium tier |
| `high_sessions` | Count of High tier |
| `returning_visitor_rate` | Ratio of sessions from returning visitors (4 decimal places) |
| `avg_engagement_velocity` | Average velocity excluding NULLs (4 decimal places) |

### 3. rpt_visitor_segments

Visitor-level segmentation:

| Column | Description |
|--------|-------------|
| `visitor_segment` | 'Power User' (5+ sessions), 'Regular' (2-4 sessions), 'One-Time' (1 session) |
| `visitor_count` | Number of unique visitors |
| `total_sessions` | Total sessions from segment |
| `avg_sessions_per_visitor` | Average sessions (2 decimal places) |
| `total_conversions` | Total conversions |
| `conversion_rate` | Ratio (4 decimal places) |

## Output Expectations

- Total sessions: 5029
- Bounce sessions: 2530
- All metrics must be deterministic and idempotent

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Handle ties in NTILE appropriately (use deterministic sorting)
- Ensure idempotent execution (multiple runs should produce same results)
- Install any additional libraries as needed
