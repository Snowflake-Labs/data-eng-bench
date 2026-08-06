# Receivables Aging Buckets (Payments + Credits)

Finance needs an as-of receivables aging model that accounts for payment applications, customer credits, and data-quality edge cases.

## Your Task

Create a new dbt model in the existing project.

## Files
- DuckDB: `/app/dbt_models_duckdb/models/marts/finance/fact_receivables_aging.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/finance/fact_receivables_aging.sql`

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

## Environment

- **Reference date**: `2026-06-30`

Run `dbt deps` before `dbt run`.
Use `var('reference_date', '2026-06-30')` so evaluation can override the reference date.

## Requirements

### Build Stability
- The model must build successfully on two consecutive `dbt run` executions without manual cleanup; assume source data can change between runs.

### Model Location
`models/marts/finance/fact_receivables_aging.sql`

### Sources
Use:
- `{{ ref('stg_finance__customer_invoices') }}` (base invoices)
- `{{ ref('stg_finance__customer_payment_applications') }}`
- `{{ ref('stg_finance__customer_payments') }}`
- `{{ ref('stg_finance__customer_credits') }}`

### Grain
- One row per `invoice_id` from the base invoice source (do not drop invoices with no payments/credits).

### Payment Application Filtering
1) Define `business_reference_date` as:
   - if reference date is Saturday, use previous Friday
   - if reference date is Sunday, use previous Friday
   - otherwise use the reference date
2) Only include applications whose payment is `POSTED` and has `payment_date` on or before `business_reference_date`.
3) Only include applications with `applied_at` on or before `business_reference_date`.
4) Track `first_payment_date` as the minimum `payment_date` per invoice from filtered applications.

### Credit Filtering
- Include credits only when `reason` is one of: `Refund`, `Return`, `Adjustment`, `Promotion`.
- `credit_available = greatest(least(coalesce(balance, amount), amount), 0)`
- Exclude credits with `created_at` null or `created_at` after the `business_reference_date`.
- `customer_credit_balance = sum(credit_available)` per `customer_id`.
- `overapplied_credit_pool = sum(overapplied_amount)` per `customer_id`.
- `total_credit_pool = customer_credit_balance + overapplied_credit_pool`.

### Effective Invoice Date
- `effective_invoice_date` is the earliest non-null date among `invoice_date`, `created_at` (cast to date), and `first_payment_date`.
- If all three are null, use `due_date`.
- If all are null, leave `effective_invoice_date` null.

### Customer First Activity Date
- `customer_first_activity_date` is the earliest non-null date among:
  - minimum `invoice_date` per customer
  - minimum `created_at` per customer (cast to date)
  - minimum `first_payment_date` per customer
  - minimum eligible credit `created_at` per customer (after credit filtering)
- If all are null, leave `customer_first_activity_date` null.

### Amount Logic
- `total_amount = coalesce(subtotal, 0) + coalesce(tax_amount, 0)`
- `applied_amount_raw = sum(amount_applied)` from filtered applications per invoice
- `applied_amount = applied_amount_raw` when `applied_amount_raw > 0`, otherwise `coalesce(amount_paid, 0)`
  - This fallback applies even when applications exist but net to zero.
- `overapplied_amount = greatest(applied_amount - total_amount, 0)`
- `gross_outstanding_amount = total_amount - least(applied_amount, total_amount)`
- `outstanding_amount = gross_outstanding_amount - credit_applied`

### Credit Allocation (Waterfall)
Allocate `total_credit_pool` to invoices with `gross_outstanding_amount > 0` in this order:
1) `effective_due_date` ascending, nulls last
2) `effective_invoice_date` ascending, nulls last
3) `invoice_id` ascending

Let `cum_outstanding` be the cumulative sum of `gross_outstanding_amount` in that order. Then:

```
credit_applied = greatest(
  least(total_credit_pool - (cum_outstanding - gross_outstanding_amount), gross_outstanding_amount),
  0
)
```

### Date Logic
- `effective_due_date`:
  - if `due_date` is not null and `due_date >= effective_invoice_date`, use `due_date`
  - otherwise use `effective_invoice_date + interval '30 days'`
- `days_past_due`:
  - 0 when `outstanding_amount = 0`
  - otherwise `date_diff('day', effective_due_date, business_reference_date)`

### Payment Status
- `CREDIT` when `overapplied_amount > 0`
- `PAID` when `outstanding_amount = 0`
- `OPEN` otherwise

### Aging Bucket Rules (use reference date)
- **CREDIT**: `payment_status = 'CREDIT'`
- **PAID**: `outstanding_amount = 0`
- **CURRENT**: `days_past_due < 0`
- **0-30**: `days_past_due` between 0 and 30
- **31-60**: `days_past_due` between 31 and 60
- **61-90**: `days_past_due` between 61 and 90
- **91-120**: `days_past_due` between 91 and 120
- **120+**: `days_past_due > 120`

### Output Columns
One row per invoice with:

| Column | Description |
|--------|-------------|
| invoice_id | Invoice identifier |
| invoice_number | Invoice number |
| customer_id | Customer identifier |
| invoice_date | Invoice date |
| due_date | Due date from source |
| business_reference_date | Weekend-adjusted reference date |
| customer_first_activity_date | Earliest customer activity date per rules |
| effective_invoice_date | Earliest non-null invoice date per rules |
| effective_due_date | Due date after applying fallback logic |
| subtotal | Invoice subtotal |
| tax_amount | Tax amount |
| total_amount | `coalesce(subtotal, 0) + coalesce(tax_amount, 0)` |
| applied_amount | Filtered application sum, or `amount_paid` when no applications |
| first_payment_date | Minimum filtered payment_date per invoice |
| overapplied_amount | `greatest(applied_amount - total_amount, 0)` |
| gross_outstanding_amount | `total_amount - least(applied_amount, total_amount)` |
| customer_credit_balance | Sum of eligible credit balances for the customer |
| overapplied_credit_pool | Sum of overapplied amounts for the customer |
| total_credit_pool | `customer_credit_balance + overapplied_credit_pool` |
| credit_applied | Credit allocated to this invoice (waterfall) |
| outstanding_amount | `gross_outstanding_amount - credit_applied` |
| payment_count | Count of distinct payment_id from filtered applications |
| latest_payment_date | Max payment_date from filtered applications |
| payment_status | `CREDIT`, `PAID`, or `OPEN` per rules above |
| days_past_due | 0 when paid/credit, else date_diff using effective_due_date |
| aging_bucket | Bucket per rules above |

## Guidelines
- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
