# Purchase Order to Receipt Three-Way Matching with Variance Analysis and Risk Scoring

Build a dbt model that implements three-way matching for purchase orders: matching PO lines to receipts to supplier invoices. The system must identify discrepancies in quantities, prices, and timing, apply tolerance rules, flag exceptions for review, and calculate a composite risk score for prioritizing invoice reviews.

## Background

Your procurement team manually reviews hundreds of invoices each week. They need an automated system that compares what was ordered (PO), what was received (receipt), and what was billed (invoice) to catch errors and prevent overpayment. Additionally, they want a risk-based prioritization system to focus on the highest-risk invoices first.

## Available Data

The staging models are pre-built and ready to use:

**Purchase Orders** (`models/staging/procurement/`):
- `stg_procurement__purchase_orders` - PO header with supplier, dates, status
  - Columns: `po_id`, `po_number`, `supplier_id`, `warehouse_id`, `status`, `total_amount`, `currency_code`, `expected_date`, `ordered_at`, `created_by`, `created_at`, `updated_at`
- `stg_procurement__purchase_order_lines` - line items on each PO
  - Columns: `po_line_id`, `po_id`, `line_number`, `variant_id`, `sku`, `quantity_ordered`, `quantity_received`, `unit_price`, `line_total`, `created_at`
- `stg_procurement__purchase_order_receipts` - receipt headers
  - Columns: `receipt_id`, `receipt_number`, `po_id`, `received_at`, `received_by`, `status`, `created_at`
- `stg_procurement__purchase_order_receipt_lines` - individual receipt line items
  - Columns: `receipt_line_id`, `receipt_id`, `po_line_id`, `quantity_received`, `quantity_accepted`, `quantity_rejected`, `reject_reason`, `created_at`

**Supplier Invoices** (`models/staging/procurement/`):
- `stg_procurement__supplier_invoices` - invoice headers from suppliers
  - Columns: `invoice_id`, `invoice_number`, `supplier_id`, `po_id`, `invoice_date`, `due_date`, `total_amount`, `currency_code`, `status`, `created_at`, `updated_at`
- `stg_procurement__supplier_invoice_lines` - invoice line items
  - Columns: `invoice_line_id`, `invoice_id`, `po_line_id`, `description`, `quantity`, `unit_price`, `line_total`, `created_at`

**Suppliers** (`models/staging/procurement/`):
- `stg_procurement__suppliers` - supplier master data
  - Columns: `supplier_id`, `supplier_code`, `supplier_name`, `supplier_type`, `payment_terms`, `currency_code`, `lead_time_days`, `min_order_value`, `rating`, `status`, `created_at`, `updated_at`

**Note**: The staging models read from source tables in the `PROCUREMENT` schema. Your solution should reference the staging models using `{{ ref('stg_procurement__table_name') }}` syntax, not the raw schema tables.

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

## Project Setup

- DuckDB dbt project: `/app/dbt_models_duckdb`
- Snowflake dbt project: `/app/dbt_models_snowflake`

Build in the marts layer under `models/marts/`. Do not modify the staging layer.

## Required Output

Create a single model called `three_way_match.sql` in `models/marts/` with these columns:

| Column | Type | Description |
|--------|------|-------------|
| `match_id` | VARCHAR | Unique identifier for each match record (generate using po_line_id) |
| `po_id` | VARCHAR | Purchase order ID |
| `po_number` | VARCHAR | PO number for reference |
| `po_line_id` | VARCHAR | PO line being matched |
| `supplier_id` | VARCHAR | Supplier ID |
| `supplier_name` | VARCHAR | Supplier name |
| `supplier_rating` | DECIMAL | Current supplier rating (1-5 scale) |
| `variant_id` | VARCHAR | Product variant being purchased |
| `sku` | VARCHAR | SKU code |
| `po_quantity` | DECIMAL | Quantity ordered on PO |
| `po_unit_price` | DECIMAL | Unit price on PO |
| `po_line_total` | DECIMAL | Total amount on PO line |
| `receipt_quantity` | DECIMAL | Total quantity received across all receipts |
| `accepted_quantity` | DECIMAL | Quantity accepted (not rejected) |
| `rejected_quantity` | DECIMAL | Quantity rejected with issues |
| `rejection_rate` | DECIMAL | Percentage of received quantity that was rejected |
| `invoice_quantity` | DECIMAL | Quantity billed on invoice |
| `invoice_unit_price` | DECIMAL | Unit price on invoice |
| `invoice_line_total` | DECIMAL | Total amount invoiced |
| `quantity_variance` | DECIMAL | Difference: invoice_quantity - accepted_quantity |
| `quantity_variance_pct` | DECIMAL | Percentage variance: (invoice_qty - accepted_qty) / accepted_qty * 100 |
| `price_variance` | DECIMAL | Difference: invoice_unit_price - po_unit_price |
| `price_variance_pct` | DECIMAL | Percentage variance: (inv_price - po_price) / po_price * 100 |
| `total_variance` | DECIMAL | Difference: invoice_line_total - (accepted_quantity * po_unit_price) |
| `expected_amount` | DECIMAL | Expected invoice amount: accepted_quantity * po_unit_price |
| `quantity_match_status` | VARCHAR | Result of quantity matching logic |
| `price_match_status` | VARCHAR | Result of price matching logic |
| `overall_match_status` | VARCHAR | Final match determination |
| `exception_reasons` | VARCHAR | Concatenated list of all exception reasons |
| `exception_count` | INTEGER | Number of distinct exceptions flagged |
| `risk_score` | DECIMAL | Composite risk score (0-100) for prioritization |
| `risk_category` | VARCHAR | Risk category: LOW, MEDIUM, HIGH, CRITICAL |
| `recommended_action` | VARCHAR | What should be done with this match |
| `days_to_invoice` | INTEGER | Days between PO date and invoice date |
| `days_receipt_to_invoice` | INTEGER | Days between first receipt and invoice |
| `receipt_count` | INTEGER | Number of separate receipts for this PO line |
| `invoice_count` | INTEGER | Number of separate invoices for this PO line |

## Business Rules

### 1. Quantity Matching
Compare the quantity invoiced to the quantity accepted (not just received). Apply rules **strictly in this precedence order** - once a rule matches, stop checking further rules:

1. **NO_RECEIPT**: no receipts exist for this PO line (receipt_quantity is NULL or 0)
2. **EXACT_MATCH**: invoice_quantity equals accepted_quantity exactly
3. **WITHIN_TOLERANCE**: variance is within the configured percentage AND unit thresholds (both conditions must be met)
4. **OVER_BILLED**: invoice_quantity exceeds accepted_quantity by more than tolerance
5. **UNDER_BILLED**: invoice_quantity is less than accepted_quantity by more than tolerance
6. **PARTIAL_RECEIPT**: only applies if none of the above matched AND receipt_quantity < po_quantity

**Important**: A record may satisfy multiple conditions (e.g., EXACT_MATCH and PARTIAL_RECEIPT). Always apply the first matching rule in the precedence order above. For example, if invoice_quantity = accepted_quantity = 71 AND receipt_quantity < po_quantity, flag as EXACT_MATCH (not PARTIAL_RECEIPT).

### 2. Price Matching
Compare the invoice unit price to the PO unit price. Apply rules **strictly in this precedence order**:

1. **NO_PO_PRICE**: PO unit price is null or zero
2. **EXACT_MATCH**: prices are identical
3. **WITHIN_TOLERANCE**: variance is within configured percentage AND dollar thresholds (both conditions must be met)
4. **PRICE_INCREASE**: invoice price is higher by more than tolerance (unfavorable)
5. **PRICE_DECREASE**: invoice price is lower by more than tolerance (favorable)

### 3. Overall Match Status
Combine quantity and price status into final determination:
- **APPROVED**: both quantity and price are EXACT_MATCH or WITHIN_TOLERANCE
- **REVIEW_REQUIRED**: one or more variances exceed tolerance but are under investigation thresholds
- **BLOCKED**: critical issues that must be resolved before payment
- **PENDING_RECEIPT**: waiting for goods to be received
- **UNMATCHED**: cannot perform matching due to missing data

For BLOCKED status, apply when ANY of these critical conditions exist:
- Significant price increase (exceeds configured threshold)
- Significant quantity over-billing (exceeds configured threshold)
- Large invoice amount with any variance over tolerance
- Risk score reaches CRITICAL level
- High rejection rate (exceeds configured threshold)

**Important precedence rule**: A line meeting any BLOCKED criterion is BLOCKED regardless of receipt status; BLOCKED takes precedence over PENDING_RECEIPT.

### 4. Risk Score Calculation
Calculate a composite risk score from 0-100 based on multiple weighted factors:

| Factor | Max Points | Description |
|--------|------------|-------------|
| Quantity Variance | 25 | Higher variance = more points. Scale from no variance (0) to severe (max) |
| Price Variance | 25 | Higher variance = more points. Scale from no variance (0) to severe (max) |
| Dollar Amount | 15 | Larger absolute dollar variance = more points |
| Supplier Rating | 15 | Lower supplier rating = more points. NULL rating = max points |
| Invoice Timing | 10 | More days between receipt and invoice = more points |
| Rejection Rate | 10 | Higher rejection rate = more points |

**Risk Categories** (based on total score):
- **LOW**: Minimal risk, routine processing
- **MEDIUM**: Some concerns, standard review
- **HIGH**: Elevated risk, detailed review needed
- **CRITICAL**: Severe risk, requires escalation

### 5. Exception Reasons
Build a pipe-delimited list of all issues found. Exception codes should appear in the order they are evaluated (not necessarily alphabetical). Include reason codes:
- `QTY_OVER` - quantity over-billed (when quantity_match_status = 'OVER_BILLED')
- `QTY_UNDER` - quantity under-billed (when quantity_match_status = 'UNDER_BILLED')
- `QTY_PARTIAL` - partial receipt (when quantity_match_status = 'PARTIAL_RECEIPT')
- `QTY_NONE` - no receipt (when quantity_match_status = 'NO_RECEIPT')
- `PRC_HIGH` - price higher than PO (when price_match_status = 'PRICE_INCREASE')
- `PRC_LOW` - price lower than PO (when price_match_status = 'PRICE_DECREASE')
- `PRC_MISSING` - no PO price to compare (when price_match_status = 'NO_PO_PRICE')
- `AMT_LARGE` - large dollar variance (significant total_variance amount)
- `TIMING_LATE` - invoice received long after receipt
- `HIGH_REJECT` - high rejection rate
- `MULTI_INVOICE` - multiple invoices for same PO line (when invoice_count > 1)
- `LOW_SUPPLIER_RATING` - supplier has poor rating or no rating on file

If no exceptions exist, set to 'NONE'.

**Exception Logic** - Apply these codes based on the corresponding conditions:
- `QTY_OVER`: Apply when quantity_match_status = 'OVER_BILLED'
- `QTY_UNDER`: Apply when quantity_match_status = 'UNDER_BILLED'
- `QTY_PARTIAL`: Apply when quantity_match_status = 'PARTIAL_RECEIPT'
- `QTY_NONE`: Apply when quantity_match_status = 'NO_RECEIPT'
- `PRC_HIGH`: Apply when price_match_status = 'PRICE_INCREASE'
- `PRC_LOW`: Apply when price_match_status = 'PRICE_DECREASE'
- `PRC_MISSING`: Apply when price_match_status = 'NO_PO_PRICE'
- `AMT_LARGE`: Apply when total_variance exceeds the large amount threshold
- `TIMING_LATE`: Apply when days_receipt_to_invoice exceeds the late threshold
- `HIGH_REJECT`: Apply when rejection_rate exceeds the high rejection threshold
- `MULTI_INVOICE`: Apply when invoice_count > 1
- `LOW_SUPPLIER_RATING`: Apply when supplier_rating is below acceptable level OR is NULL

### 6. Recommended Actions
Based on overall status, risk score, and exceptions, recommend one of:
- `PAY_IMMEDIATELY` - approved for payment, no issues
- `PAY_WITH_ADJUSTMENT` - pay but apply credit/debit for variances
- `HOLD_FOR_REVIEW` - requires manual review before payment
- `REQUEST_CREDIT_MEMO` - request credit from supplier for overbilling
- `CONTACT_SUPPLIER` - pricing or quantity issues need supplier clarification
- `WAIT_FOR_RECEIPT` - cannot process until goods received
- `ESCALATE_TO_MANAGEMENT` - critical risk items requiring management approval (when risk_category = 'CRITICAL')

**Action Decision Logic** (apply first matching rule):
1. If overall_match_status = 'PENDING_RECEIPT' → WAIT_FOR_RECEIPT
2. If risk_category = 'CRITICAL' → ESCALATE_TO_MANAGEMENT
3. If overall_match_status = 'APPROVED' → PAY_IMMEDIATELY
4. If quantity_match_status = 'OVER_BILLED' → REQUEST_CREDIT_MEMO
5. If price_match_status = 'PRICE_INCREASE' → CONTACT_SUPPLIER
6. If overall_match_status = 'BLOCKED' → HOLD_FOR_REVIEW
7. If quantity_match_status IN ('UNDER_BILLED', 'WITHIN_TOLERANCE') OR price_match_status IN ('PRICE_DECREASE', 'WITHIN_TOLERANCE') → PAY_WITH_ADJUSTMENT
8. Otherwise → HOLD_FOR_REVIEW

### 7. Handling Missing Data
When performing matches:
- If no receipts exist for a PO line, use po_quantity as the baseline for comparison
- If no invoice exists for a PO line, exclude from results (we only want matched records)
- If multiple receipt lines exist for one PO line, sum up quantities
- If multiple invoice lines exist for one PO line, sum up quantities and calculate weighted average price
- If supplier_rating is NULL, treat as lowest reliability (rating = 0 for risk score purposes)

### 8. Date Calculations
- `days_to_invoice` = invoice_date - po ordered_at date (extract date from timestamp)
- `days_receipt_to_invoice` = invoice_date - earliest receipt date for this PO line (not entire PO)
- Handle null dates by returning null (not zero)
- Note: These values may be negative if invoices are backdated before the PO or receipt dates

### 9. Additional Calculations
- `rejection_rate` = (rejected_quantity / receipt_quantity) * 100 (return 0 if no receipts)
- `expected_amount` = accepted_quantity * po_unit_price
- `exception_count` = number of pipe-delimited exception codes (0 if 'NONE')
- `receipt_count` = count of distinct receipt_id values for the PO line
- `invoice_count` = count of distinct invoice_id values for the PO line

## Testing Your Solution

Run these commands to test:
```bash
cd /app/dbt_models_duckdb  # or /app/dbt_models_snowflake for Snowflake
dbt run --select three_way_match
dbt test --select three_way_match
```

## Hints

- This model requires joining multiple staging tables
- Use window functions or subqueries to aggregate receipt and invoice data per PO line
- The tolerance checks require checking BOTH percentage AND absolute thresholds
- Watch for division by zero when calculating percentages
- Use COALESCE to handle nulls in calculations
- Consider using CTEs to build up the logic step by step
- Risk score calculation should use CASE statements for tiered scoring
- Exception_count can be calculated from the exception_reasons string
- Make sure to count distinct receipts and invoices, not lines

## Tolerance Configuration

The system uses the following tolerance thresholds (implement these values):
- **Quantity tolerance**: ±2% AND ±5 units (both must be satisfied)
- **Price tolerance**: ±1% AND ±$0.50 (both must be satisfied)
- **Blocked thresholds**: price increase >5%, quantity over-billed >10%, invoice >$1000 with variance
- **Risk score CRITICAL**: score ≥80
- **High rejection**: rate >25%
- **Large amount variance**: ABS(total_variance) > $500
- **Late invoice**: >30 days after receipt
- **High rejection exception**: rate >10%
- **Low supplier rating**: rating <3.0 or NULL

These thresholds represent industry-standard tolerances for three-way matching systems.

## Risk Score Tier Breakpoints

Use these breakpoints for the risk score component calculations:

| Factor | 0 pts | Low pts | Med pts | Max pts |
|--------|-------|---------|---------|---------|
| Quantity Variance | ≤2% | 2-5% (5pts) | 5-10% (15pts) | >10% (25pts) |
| Price Variance | ≤1% | 1-3% (5pts) | 3-5% (15pts) | >5% (25pts) |
| Dollar Amount | <$100 | $100-500 (5pts) | $500-1000 (10pts) | >$1000 (15pts) |
| Supplier Rating | ≥4.0 | 3.0-3.99 (5pts) | 2.0-2.99 (10pts) | <2.0/NULL (15pts) |
| Invoice Timing | ≤14 days | 15-30 days (3pts) | 31-60 days (7pts) | >60 days (10pts) |
| Rejection Rate | 0% | 1-10% (3pts) | 11-25% (7pts) | >25% (10pts) |

**Risk Categories:**
- LOW: 0-24 points
- MEDIUM: 25-49 points
- HIGH: 50-79 points
- CRITICAL: 80-100 points

## Guidelines

- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
