# Fix Return Processing Analytics Model

## Objective

Fix a dbt model with data quality issues in return processing analytics.

## Background

The operations team relies on the `rpt_return_reconciliation` model to track return processing efficiency and identify bottlenecks in the refund process. However, the model currently has issues causing invalid data in reports.

## Your Task

Fix the `rpt_return_reconciliation.sql` model to produce correct output.

- DuckDB: `/app/dbt_models_duckdb/models/marts/sales/rpt_return_reconciliation.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/sales/rpt_return_reconciliation.sql`

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
- Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank. A blank or omitted schema makes Snowflake silently default to `PUBLIC`, so your models get built in the wrong schema and the verifier cannot find them.

## Data Sources

The model uses two staging tables:
- **stg_orders__returns** — Contains return header information including identifiers, customer details, return metadata, monetary amounts, and timestamp fields. Explore the table to understand available columns.
- **stg_orders__return_lines** — Contains return line-level detail. Explore to find relevant columns for aggregation.

## Current Issues

The existing model has problems that need to be resolved:

1. Some calculated metrics show invalid values (infinity, NaN) in production reports
2. Row counts don't match expectations - some returns are missing from the output
3. A new classification column is needed for prioritizing return processing improvements

## Tasks

### 1. Fix Data Quality Issues

The model should include ALL returns from the source table without invalid numeric values. Ensure:

- No infinity or NaN values appear in any calculated columns
- All returns are included in the output (check if any filtering is excluding valid data)
- All ratio and rate calculations handle edge cases properly

### 2. Add Processing Efficiency Classification

The operations team wants a new column called `refund_velocity_tier` that classifies returns by how efficiently they were processed. This will help identify which returns experienced delays.

Use a **waterfall classification** (check conditions in order, assign first match):

#### Classification Logic

1. **critical_delay**

   - Bottom 25% slowest processors (PERCENT_RANK <= 0.25, i.e., the 25% with highest total_processing_days)
   - AND took more than 10 days to process
2. **needs_improvement**

   - Bottom 50% slowest processors (PERCENT_RANK <= 0.50)
   - OR refund completion rate below 80%
3. **acceptable**

   - Refund completion rate >= 85%
   - AND total processing days <= 7
4. **efficient**

   - Top 25% fastest processors (PERCENT_RANK >= 0.75)
   - AND refund completion rate >= 90%
5. **Default**: All other cases -> `acceptable`

#### Implementation Notes

- Use `PERCENT_RANK()` window function ordered by `total_processing_days DESC`
- Calculate percentiles **only for non-NULL** processing days
- Handle NULL values in tier classification:
  - NULL `refund_completion_rate` -> treat as 0 (worst case)
  - NULL `total_processing_days` in `> 10` check -> treat as 0 (best case, won't trigger critical)
  - NULL `total_processing_days` in `<= 7` check -> treat as very high value (worst case, won't pass)
- Check conditions in the order listed above (waterfall logic)

## Expected Output

The model should produce these columns:

- `return_id`
- `return_number`
- `order_id`
- `customer_id`
- `return_type`
- `refund_method`
- `status`
- `total_return_amount`
- `total_refund_amount`
- `return_line_count`
- `requested_at`
- `received_at`
- `processed_at`
- `days_to_receive`
- `days_to_process`
- `total_processing_days`
- `refund_completion_rate`
- `processing_efficiency`
- `refund_velocity_tier` (NEW COLUMN)

## Success Criteria

1. Model compiles and runs without errors
2. No infinity or NaN values in any numeric columns
3. Row count matches the number of returns in the source table
4. The new tier column contains valid values distributed across multiple categories
5. Classification distinguishes between fast and slow processors