# Sales Funnel Analysis

Marketing just got out of a tough budget meeting: "We're spending millions on ads but have no idea where customers drop off. Are they bouncing before viewing products? Abandoning carts? We need funnel metrics by end of day to justify our spend."

## Your Task

Create dbt models that track conversion through the purchase funnel in schema `funnel_analytics`.

(Hint: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.)

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
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Environment

- **dbt project**: Create a new dbt project at `/app/dbt_project`

## Requirements

Explore the `main` schema to find relevant tables for sessions, events, and shopping carts. You'll need to:

- Track the funnel stages: product view -> add to cart -> purchase
- Handle data quality issues (the conversion flag field has inconsistent boolean formatting across records - explore the data to identify all variations)
- Determine purchase conversion from multiple signals: the session's conversion flag AND/OR the cart's completion status
- Calculate dropoff at each stage

## Required Models

### int_session_funnel (intermediate)

Per-session funnel flags. Explore the events table to identify the correct event types for product views and cart additions.

| Column | Description |
|--------|-------------|
| session_id | Session identifier |
| visitor_id | Visitor identifier |
| customer_id | Customer identifier |
| session_start | Session start timestamp |
| has_product_view | 1 if session has a product view event, 0 otherwise |
| has_add_to_cart | 1 if session has an add-to-cart event, 0 otherwise |
| has_purchase | 1 if session converted (from any signal), 0 otherwise |
| funnel_stage | Highest stage reached: NONE, VIEW, CART, or PURCHASE |

### funnel_conversion_rates (mart)

Single-row summary of conversion rates.

| Column | Description |
|--------|-------------|
| total_sessions | All sessions |
| sessions_with_view | Sessions with product view |
| sessions_with_cart | Sessions with add to cart |
| sessions_with_purchase | Sessions that converted |
| view_rate | View / total sessions |
| view_to_cart_rate | Cart / view sessions |
| cart_to_purchase_rate | Purchase / cart sessions |
| overall_conversion_rate | Purchase / total sessions |

### funnel_dropoff_analysis (mart)

Three rows showing where users drop off.

| Column | Description |
|--------|-------------|
| dropoff_stage | BEFORE_VIEW, VIEW_TO_CART, or CART_TO_PURCHASE |
| session_count | Sessions that dropped at this stage |
| dropoff_rate | Proportion of total sessions |

## Guidelines

- Use integer 1/0 instead of boolean true/false for cross-database compatibility
- Ensure idempotent execution (multiple runs produce same results)
- Use explicit type casts where needed
- Handle NULL values appropriately
