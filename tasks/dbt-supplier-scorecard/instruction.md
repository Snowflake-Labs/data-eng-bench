# Supplier Performance Scorecard

Procurement is renegotiating contracts next month: "We've got 50 suppliers and no objective way to compare them. Late deliveries? Quality issues? Cost overruns? Give me a single score for each so I know who to keep and who to drop."

## Your Task

Create dbt models `fct_supplier_metrics` and `fct_supplier_scorecard` that calculate weighted supplier performance scores.

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

## Environment

- dbt project location: `/app/dbt_project`

### DuckDB
- Output schema: `supplier_analytics`
- Create a new standalone dbt project at `/app/dbt_project`

### Snowflake
- Output schema: `main`
- Use the pre-built project at `/app/dbt_models_snowflake` as the base
- Create a symlink: `ln -sfn /app/dbt_models_snowflake /app/dbt_project`

## dbt Profile Setup

### DuckDB Profile
- Create a `profiles.yml` with profile name `dbt_project`
- Configure with `type: duckdb` and the database path
- Set schema to `supplier_analytics`

### Snowflake Profile
- Configure `profiles.yml` in the project directory with profile name `retail_dw_master`
- Configure with `type: snowflake` using password authentication:
  - Use the environment variables for account, user, password, database, schema, warehouse, and role
  - Set schema to `main`

(Hint: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.)

## Source Data

Explore the `PROCUREMENT` schema to find tables containing:
- Supplier master data (names, codes, types, status)
- Purchase orders (with expected dates and amounts)
- Purchase order receipts (actual received dates)
- Receipt line items (quantities received, accepted, rejected)
- Supplier invoices (for cost variance analysis)

Only include ACTIVE suppliers. For metrics calculation:
- Include POs with STATUS not in ('DRAFT', 'CANCELLED')
- For delivery metrics: only count POs that have at least one receipt
- For quality metrics: only include POs where total_quantity_received > 0
- For cost metrics: only include POs that have TOTAL_AMOUNT > 0 AND at least one non-DISPUTED invoice
- Exclude DISPUTED invoices when summing invoice totals

## Definitions

- **On Time**: A PO is considered "on time" if the first receipt date is on or before the expected date
- **Acceptance Rate**: quantity_accepted / quantity_received
- **Cost Variance**: (invoice_total - po_total) / po_total

## Scoring Requirements

- **On-Time Score (40% weight)**: on_time_delivery_rate * 100
- **Quality Score (35% weight)**: acceptance_rate * 100
- **Cost Score (25% weight)**: Linear scale where -5% variance = 100, +10% variance = 0. Clamp to [0, 100] range (values below -5% get 100, above +10% get 0).
- **Composite Score**: weighted sum of three component scores
- **Tier**: PLATINUM (>=90), GOLD (>=75), SILVER (>=60), BRONZE (>=40), AT_RISK (<40)

## Output Columns - fct_supplier_metrics

| Column | Description |
|--------|-------------|
| supplier_id | Supplier identifier |
| supplier_code | Supplier code |
| supplier_name | Supplier name |
| supplier_type | Type of supplier |
| total_pos | Total purchase orders |
| on_time_pos | Count of on-time POs |
| on_time_delivery_rate | on_time_pos / total_pos |
| avg_days_late | Average days late for late POs |
| total_quantity_received | Total items received |
| total_quantity_accepted | Total items accepted |
| total_quantity_rejected | Total items rejected |
| overall_acceptance_rate | total_accepted / total_received |
| overall_defect_rate | total_rejected / total_received |
| total_po_value | Sum of PO amounts |
| total_invoice_value | Sum of invoice amounts |
| overall_cost_variance | total_invoice - total_po |
| overall_cost_variance_pct | cost_variance / total_po |

## Output Columns - fct_supplier_scorecard

| Column | Description |
|--------|-------------|
| supplier_id | Supplier identifier |
| supplier_code | Supplier code |
| supplier_name | Supplier name |
| supplier_type | Type of supplier |
| on_time_delivery_rate | % of POs delivered on time |
| on_time_score | Score 0-100 |
| acceptance_rate | % of items accepted |
| quality_score | Score 0-100 |
| cost_variance_pct | Invoice vs PO variance |
| cost_score | Score 0-100 |
| composite_score | Weighted overall score |
| performance_tier | PLATINUM/GOLD/SILVER/BRONZE/AT_RISK |

## Model Naming

Use these exact model names:
- **Staging**: `stg_sp__suppliers`, `stg_sp__purchase_orders`, `stg_sp__purchase_order_receipts`, `stg_sp__purchase_order_receipt_lines`, `stg_sp__supplier_invoices`
- **Intermediate**: `int_po_delivery_performance`, `int_po_quality_performance`, `int_po_cost_performance`
- **Marts**: `fct_supplier_metrics`, `fct_supplier_scorecard`

## Guidelines
- Use `DATEDIFF('day', date2, date1)` for date difference calculations
- Use `cast()`, `coalesce()`, `round()`, `nullif()` which work on both backends
- For Snowflake, run dbt with `--select` specifying model names explicitly

Install additional libraries as needed.
