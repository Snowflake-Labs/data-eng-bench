# Order Line DQ Enforcement + Net Pricing Corrections

The analytics team wants standardized DQ flags on the sales order line detail mart. The macros already exist in `macros/data_quality/`, but the model does not use them. They also want net pricing fixes applied consistently so downstream dashboards stop applying their own logic.

## Your Task

Update the existing model:
- DuckDB: `/app/dbt_models_duckdb/models/marts/sales/fct_order_line_detail.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/sales/fct_order_line_detail.sql`

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

Run `dbt deps` before `dbt run`.

## Requirements

### 1) Normalize SKU and product name
- `sku` must be:
  `COALESCE(NULLIF(TRIM(pv.sku), ''), NULLIF(TRIM(ol.sku), ''))`
- `product_name` must be:
  `COALESCE(NULLIF(TRIM(p.product_name), ''), NULLIF(TRIM(ol.product_name), ''))`
- Track whether each fallback was used (you will need this for `dq_format_corrected`).
  - `sku_fallback` is TRUE only when `pv.sku` is NULL/empty **and** `ol.sku` is non-empty.
  - `product_name_fallback` is TRUE only when `p.product_name` is NULL/empty **and** `ol.product_name` is non-empty.

### 2) Add product category leaf
Join `stg_product__product_categories` and compute a `product_category_leaf` column:
- Join on `p.primary_category_id = pc.category_id` (left join; do not drop order lines).
- `product_category_leaf` rules:
  - If `pc.category_path` is non-empty, use the text **after the last** `>` (trim whitespace).
  - Else if `pc.category_name` is non-empty, use `pc.category_name`.
  - Else fallback to `product_name`.

### 3) Recompute `line_total` and `line_profit`
Use this calculation for **all** rows:
```
calc_line_total = quantity_ordered * unit_price - discount_amount + tax_amount
```
Replace the output `line_total` with `calc_line_total`.

Set a `line_total_corrected` flag when:
- `abs(calc_line_total - ol.line_total) > 0.01`

Recompute `line_profit` using the corrected line total and a cost fallback:
```
line_profit = calc_line_total - quantity_ordered * COALESCE(pv.cost_price, 0)
```

### 4) Add net unit price
Compute the net per-unit price from the corrected line total:
```
net_unit_price = round(calc_line_total / nullif(quantity_ordered, 0), 2)
```
Set a `unit_price_net_corrected` flag when:
- `abs(net_unit_price - ol.unit_price) > 0.01` (treat NULL as FALSE)

### 5) Fix macro behavior for cross-database compatibility
Update the macros in `macros/data_quality/`:
- `add_dq_flags` must treat empty strings as missing (use `TRIM(CAST(col AS VARCHAR)) = ''`).
- `dq_flag_potential_pii` must use conditional logic for regex matching:
  `{% if target.type == 'duckdb' %}REGEXP_MATCHES{% else %}REGEXP_LIKE{% endif %}`
- `dq_flag_iqr_outlier` must use conditional logic for percentile functions:
  `{% if target.type == 'duckdb' %}quantile_cont(column, 0.25){% else %}PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY column){% endif %}`

### 6) Required field flags (`add_dq_flags`)
Use `add_dq_flags` with required columns:
- `order_line_id`
- `order_id`
- `order_number`
- `sku` (after COALESCE)
- `product_name` (after COALESCE)
- `product_category_leaf`
- `quantity_ordered`
- `unit_price`
- `line_total` (the recomputed value)
- `net_unit_price`

### 7) Additional DQ flags using macros and logic
Add these DQ columns at the end of the select:
- `dq_revenue_flag` using `dq_flag_revenue_anomaly` on
  `CASE WHEN ol.status IN ('CREDIT','RETURNED') THEN ABS(line_total) ELSE line_total END`
- `dq_quantity_flag` using `dq_flag_quantity_anomaly` on
  `CASE WHEN ol.status IN ('CREDIT','RETURNED') THEN ABS(quantity_ordered) ELSE quantity_ordered END`
- `dq_duplicate_flag` using `dq_flag_potential_duplicate` with partition:
  - `order_id`, `product_id`
- `dq_shipped_vs_ordered_valid` using `dq_check_shipped_vs_ordered(quantity_shipped, quantity_ordered, tolerance_pct=5)`
- `dq_return_vs_shipped_valid` using `dq_check_shipped_vs_ordered(quantity_returned, quantity_shipped, tolerance_pct=0)`
  - only apply when `ol.status = 'RETURNED'`, else TRUE
- `dq_status_qty_valid` (custom boolean):
  - `PENDING`: `quantity_shipped = 0` AND `quantity_returned = 0`
  - `SHIPPED`: `quantity_shipped > 0`
  - `RETURNED`: `quantity_returned > 0`
  - `CREDIT`: `quantity_ordered < 0` AND `line_total < 0`
  - otherwise TRUE
- `dq_unit_price_iqr_flag` using `dq_flag_iqr_outlier` on
  `CASE WHEN ol.status IN ('CREDIT','RETURNED') THEN NULL ELSE net_unit_price END`
  - partition by `product_id`
- `dq_order_total_match` using `dq_check_order_total_matches_lines(grand_total, adjusted_line_total, order_id, tolerance=0.01)`
  - where `adjusted_line_total = CASE WHEN ol.status = 'CREDIT' THEN 0 ELSE line_total END`
- `dq_pii_flag` using `dq_flag_potential_pii(COALESCE(notes, analyst_notes))`
- `dq_line_total_nonnegative` using `dq_check_range(line_total, min_val=0, allow_null=true)`
  - but **override to TRUE** when `ol.status = 'CREDIT'`
- `dq_discount_rate_flag` (string):
  - `discount_rate = discount_amount / nullif(unit_price * quantity_ordered, 0)`
  - `CASE`
    - `WHEN ol.status IN ('CREDIT','RETURNED') THEN NULL`
    - `WHEN discount_rate IS NULL THEN NULL`
    - `WHEN discount_rate < 0 THEN 'NEGATIVE_DISCOUNT'`
    - `WHEN discount_rate > 1 THEN 'DISCOUNT_EXCEEDS_PRICE'`
    - `WHEN discount_rate > 0.70 THEN 'HIGH_DISCOUNT'`
    - `ELSE NULL`
- `dq_margin_flag` (string):
  - `margin_pct = line_profit / nullif(line_total, 0)`
  - `CASE`
    - `WHEN ol.status IN ('CREDIT','RETURNED') THEN NULL`
    - `WHEN line_total = 0 THEN 'ZERO_REVENUE'`
    - `WHEN line_profit < 0 THEN 'NEGATIVE_MARGIN'`
    - `WHEN margin_pct > 0.80 THEN 'EXCESS_MARGIN'`
    - `ELSE NULL`
- `dq_line_dates_valid` using `dq_check_date_sequence(['order_ordered_at', 'line_created_at', 'line_updated_at'])`
- `dq_category_missing` (boolean):
  - TRUE when `p.primary_category_id` is NULL, or no category match, or `pc.category_name` is empty.

### 8) Override placeholder flags
The macro outputs `dq_format_corrected`, `dq_duplicate_suspected`, and `dq_late_arriving` as placeholders.
Replace them in the final select with:
- `dq_format_corrected`: TRUE when `line_total_corrected` OR `unit_price_net_corrected` OR SKU fallback used OR product_name fallback used
- `dq_duplicate_suspected`: `dq_duplicate_flag IS NOT NULL`
- `dq_late_arriving`: TRUE when `ol.updated_at > o.ordered_at + interval '2 days'` **and** status not in (`CREDIT`, `RETURNED`), else FALSE

### 9) Override `dq_is_valid`
`dq_is_valid` must be TRUE only when:
- `dq_missing_required` is FALSE
- `dq_line_total_nonnegative` is TRUE
- `dq_shipped_vs_ordered_valid` is TRUE
- `dq_return_vs_shipped_valid` is TRUE
- `dq_status_qty_valid` is TRUE
- `dq_order_total_match` is TRUE
- `dq_line_dates_valid` is TRUE
- `dq_category_missing` is FALSE
- `dq_revenue_flag`, `dq_quantity_flag`, `dq_unit_price_iqr_flag`, `dq_pii_flag`, `dq_discount_rate_flag`, and `dq_margin_flag` are all NULL
- `dq_duplicate_suspected` is FALSE

### Output Expectations
- Preserve existing columns and names
- Replace `line_total` with the recomputed value
- Recompute `line_profit` as specified
- Add `product_category_leaf`
- Add `line_total_corrected`, `net_unit_price`, and `unit_price_net_corrected`
- Add the DQ columns at the end of the select
- No NULLs introduced in existing fields
- Row count must match `stg_orders__order_lines`

## Guidelines
- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
