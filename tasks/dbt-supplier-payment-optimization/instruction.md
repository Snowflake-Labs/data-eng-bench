# Supplier Payment Optimization with Dynamic Discount Analysis and Risk Assessment

The finance team needs to optimize supplier invoice payments. Goals:
- Take advantage of early payment discounts when ROI is worthwhile
- Maintain good supplier relationships
- Manage cash flow effectively  
- Prioritize critical payments
- Assess supplier risk for payment decisions

Create a dbt model that analyzes open invoices with prioritization scoring, cash flow projections, risk assessment, and annualized ROI calculations for early payment discounts.

## Available Data

Your data warehouse has the following tables in the PROCUREMENT and FINANCE schemas:

**PROCUREMENT Schema:**
- `SUPPLIER_INVOICES` - tracks all invoices from suppliers with amounts, due dates, and current status
- `SUPPLIERS` - master data including supplier names, ratings, and payment terms they offer
- `PURCHASE_ORDERS` - links invoices back to original purchase orders

**FINANCE Schema:**
- `CURRENCY_EXCHANGE_RATES` - daily foreign exchange rates for currency conversion

Use the existing dbt staging models that have already been set up for you. You can explore these with `dbt ls` to understand the available columns and run `dbt run --select tag:staging` to see sample data.

## Project Setup

- **dbt project location:**
  - DuckDB: `/app/dbt_models_duckdb`
  - Snowflake: `/app/dbt_models_snowflake`

The staging layer (`models/staging/`) has these models ready to use:
- `stg_procurement__supplier_invoices`
- `stg_procurement__suppliers`
- `stg_procurement__purchase_orders`
- `stg_finance__currency_exchange_rates`

## Your Task

Create one comprehensive SQL model in the marts layer:
- **Location:** `models/marts/supplier_payment_optimization.sql`
- **Approach:** Use a single SQL file with CTEs (Common Table Expressions) to build up your logic step by step

This should showcase your ability to write complex analytical SQL with proper joins, aggregations, window functions, and business logic.

## What the Finance Team Needs

Your output model should help the finance team answer questions like:
- Which invoices should we pay first?
- Where can we save money with early payment discounts?
- What's the annualized return on taking early payment discounts?
- How overdue are our payments?
- What's our projected cash outflow over the next few weeks?
- Which suppliers are high-risk based on payment history and other factors?
- What's the optimal payment strategy for each invoice?

**Required output columns** (your model must have all of these with exact column names):

**Invoice Identification:**
- `invoice_id`, `supplier_id`, `supplier_name`, `supplier_rating`
- `invoice_date`, `due_date`, `invoice_amount`, `currency_code`

**Currency Conversion:**
- `amount_usd` - all amounts standardized to USD for comparison

**Aging Analysis:**
- `days_until_due` - how many days until (or since) the due date, calculated from your analysis date
- `aging_bucket` - categorize as overdue or not yet due
- `days_past_optimal` - days past the optimal payment window (0 if still within window)

**Discount Opportunity:**
- `payment_terms_code` - the supplier's payment terms
- `early_payment_discount_pct` - what discount % is offered
- `discount_deadline` - last day to get the discount
- `potential_savings_usd` - how much could be saved
- `discount_opportunity_status` - whether discount is still available

**Discount ROI Analysis:**
- `annualized_discount_roi` - the annualized return on investment of taking the early payment discount
- `discount_roi_tier` - categorize the ROI as 'Exceptional', 'Good', 'Marginal', or 'Not Applicable'

**Payment Prioritization:**
- `payment_priority_score` - calculated score for payment importance
- `priority_rank` - ranking from most to least important
- `priority_tier` - grouping into Critical/High/Medium/Low tiers

**Supplier Risk Assessment:**
- `supplier_risk_score` - calculated risk score based on multiple factors (0-100)
- `supplier_risk_category` - categorize as 'Low Risk', 'Medium Risk', 'High Risk', or 'Critical Risk'
- `supplier_invoice_concentration` - percentage of total payables from this supplier

**Cash Flow Planning:**
- `recommended_payment_date` - when this invoice should optimally be paid
- `payment_strategy` - recommended strategy: 'Take Discount', 'Pay On Due Date', 'Immediate Payment', 'Defer Payment'
- `cash_outflow_week` - which week the payment falls in
- `cumulative_outflow_usd` - running total of cash outflows
- `weekly_outflow_usd` - total payments due in the same week

**Working Capital Impact:**
- `working_capital_days` - days of working capital impact (days between invoice date and recommended payment)
- `float_benefit_usd` - estimated benefit of holding cash until payment date (using 5% annual rate)

## Business Logic to Implement

### 1. Currency Normalization
All invoice amounts need to be converted to US Dollars for fair comparison. Look up the appropriate exchange rate from the currency exchange rates table based on when the invoice was issued. If an invoice is already in USD, no conversion is needed. For other currencies, find the exchange rate that was in effect on (or most recently before) the invoice date.

If you can't find any exchange rate for a particular currency, that invoice should be excluded from the analysis.

### 2. Payment Aging Analysis  
The finance team wants to know the payment status as of **December 31, 2024** (use the date `2024-12-31` as your analysis date). For each invoice, calculate how many days remain until the due date (or how many days overdue it is) using the formula: `due_date - analysis_date`.

Categorize invoices into the following exact aging buckets based on `days_until_due`:
- **'Not Yet Due'** - when `days_until_due > 0`
- **'1-30 Days Overdue'** - when `days_until_due >= -30 AND days_until_due <= 0`
- **'31-60 Days Overdue'** - when `days_until_due >= -60 AND days_until_due < -30`
- **'61-90 Days Overdue'** - when `days_until_due >= -90 AND days_until_due < -60`
- **'Over 90 Days Overdue'** - when `days_until_due < -90`

**Important:** The aging bucket strings must match exactly as shown above (including capitalization and spacing).

Calculate `days_past_optimal` as the number of days past the optimal payment window. The optimal window is defined as:
- If a discount is available: pay by discount deadline
- If no discount: pay by due date
Set to 0 if still within the optimal window, otherwise the number of days past the optimal date.

### 3. Early Payment Discount Parsing
Suppliers often offer discounts for paying early. These are typically written in formats like "2/10 Net 30" which means "take 2% discount if you pay within 10 days, otherwise full amount is due in 30 days." 

Parse the payment_terms to extract:
- The discount percentage being offered
- How many days you have to pay to get the discount  
- Calculate the deadline date (invoice date + discount days)

Then determine the discount status using these exact values for `discount_opportunity_status`:
- **'Available'** - when the discount deadline has not yet passed (discount_deadline >= analysis_date)
- **'Expired'** - when the discount deadline has passed (discount_deadline < analysis_date)
- **'Not Applicable'** - when no discount is offered in the payment terms

**Important:** The discount_opportunity_status values must match exactly as shown above (including capitalization).

Calculate the potential dollar savings using the formula: amount_usd × (early_payment_discount_pct ÷ 100), rounded to 2 decimal places. Set potential_savings_usd to 0 when the discount status is 'Expired' or 'Not Applicable'.

### 4. Discount ROI Analysis
For available discounts, calculate the annualized return on investment. This helps the finance team understand the true cost of not taking a discount.

The formula for annualized ROI is:
```
annualized_discount_roi = (discount_pct / (100 - discount_pct)) × (365 / (net_days - discount_days)) × 100
```

Where:
- `discount_pct` is the early payment discount percentage
- `net_days` is the normal payment terms (e.g., 30 in "2/10 Net 30")
- `discount_days` is the discount window (e.g., 10 in "2/10 Net 30")

Round to 2 decimal places. Set to 0 when discount is 'Expired' or 'Not Applicable'.

Categorize the ROI into tiers using these exact values for `discount_roi_tier`:
- **'Exceptional'** - when annualized_discount_roi >= 36.0 (equivalent to 36%+ annual return)
- **'Good'** - when annualized_discount_roi >= 18.0 AND < 36.0
- **'Marginal'** - when annualized_discount_roi > 0 AND < 18.0
- **'Not Applicable'** - when annualized_discount_roi = 0

### 5. Supplier Risk Assessment
Calculate a supplier risk score (0-100) based on multiple factors:

**Overdue Invoice Weight** (35% of score): Based on how overdue invoices are from this supplier:
- Over 90 days overdue: 1.0
- 61-90 days overdue: 0.75
- 31-60 days overdue: 0.5
- 1-30 days overdue: 0.25
- Not yet due: 0.0
Multiply by 35 for this component.

**Invoice Concentration Weight** (25% of score): Calculate what percentage of total payables (sum of all amount_usd) comes from this supplier. Normalize this concentration ratio (cap at 0.5 or 50% max) and multiply by 2 to get a 0-1 scale, then multiply by 25.

**Supplier Rating Inverse** (20% of score): Lower-rated suppliers are higher risk. Use formula: ((5 - supplier_rating) / 4) × 20. If rating is NULL, treat as 3.0.

**Invoice Age Factor** (20% of score): Older unpaid invoices increase risk. Calculate days since invoice_date divided by 180 (cap at 1.0), then multiply by 20.

Sum all four components for the final `supplier_risk_score` (0-100 scale). Round to 2 decimal places.

Categorize risk using these exact values for `supplier_risk_category`:
- **'Low Risk'** - when supplier_risk_score < 25
- **'Medium Risk'** - when supplier_risk_score >= 25 AND < 50
- **'High Risk'** - when supplier_risk_score >= 50 AND < 75
- **'Critical Risk'** - when supplier_risk_score >= 75

Calculate `supplier_invoice_concentration` as the percentage of total payables from this supplier (0-100 scale), rounded to 2 decimal places.

### 6. Payment Priority Scoring
Not all invoices should be treated equally. Build a weighted scoring system that considers multiple factors:

**Overdue Status** (30% weight): More overdue invoices should score higher. Assign normalized weights based on aging:
- Over 90 days overdue: highest weight (1.0)
- 61-90 days overdue: high weight (0.8)
- 31-60 days overdue: medium weight (0.6)
- 1-30 days overdue: low weight (0.4)
- Not yet due: no weight (0.0)

Multiply this weight by 30 to get the overdue component score.

**Supplier Risk** (25% weight): Higher risk suppliers should be paid sooner to avoid relationship damage. Normalize supplier_risk_score (divide by 100), then multiply by 25.

**Discount Opportunity** (20% weight): If an early payment discount is still available, that should increase priority. Also consider the ROI tier:
- Exceptional ROI: 1.0
- Good ROI: 0.75
- Marginal ROI: 0.5
- Not Applicable or Expired: 0.0

Multiply by 20 for the discount component score.

**Invoice Amount** (15% weight): Larger invoices should get somewhat higher priority. Normalize against the largest invoice amount in the dataset (divide amount_usd by max amount_usd), then multiply by 15 for the amount component score.

**Supplier Rating** (10% weight): Factor in the supplier's rating (1-5 scale where 5 is best). If a supplier has no rating (NULL), treat it as a 3.0 (average). Normalize to 0-1 by dividing by 5, then multiply by 10 for the rating component score.

Combine these five factors into a single priority score on a 0-100 scale by summing all component scores. Round to 2 decimal places.

### 7. Priority Ranking and Tiers
Rank all invoices by their priority score (highest priority = rank 1). When scores are tied, use due date as a tiebreaker (earlier due date wins), and if still tied, use invoice_id.

Group the ranked invoices into four equal quartile tiers using these exact values for `priority_tier`:
- **'Critical'** - top 25% (highest priority)
- **'High'** - next 25%
- **'Medium'** - next 25%  
- **'Low'** - bottom 25%

**Important:** The priority_tier values must match exactly as shown above (including capitalization).

### 8. Payment Strategy Recommendation
For each invoice, recommend a payment strategy using these exact values for `payment_strategy`. Apply the rules in order (first matching rule wins):
1. **'Take Discount'** - when discount_opportunity_status is 'Available' AND discount_roi_tier is 'Exceptional' or 'Good'
2. **'Immediate Payment'** - when the invoice is overdue (any aging bucket containing 'Overdue') AND supplier_risk_category is 'High Risk' or 'Critical Risk'
3. **'Defer Payment'** - when not overdue AND supplier_risk_category is 'Low Risk' AND days_until_due > 14
4. **'Pay On Due Date'** - default for all remaining invoices

### 9. Payment Date Recommendation
For each invoice, recommend when it should be paid based on the payment strategy:
- If payment_strategy is 'Take Discount', recommend paying on the discount_deadline
- If payment_strategy is 'Immediate Payment', recommend paying on the analysis date (2024-12-31)
- If payment_strategy is 'Defer Payment', recommend paying on the due_date
- If payment_strategy is 'Pay On Due Date', recommend paying on the due_date

### 10. Cash Flow Projection
Calculate which week number each payment falls into based on the recommended payment date using the database's `WEEKOFYEAR()` function. Store this in the `cash_outflow_week` column.

Calculate `weekly_outflow_usd` as the total of all payments recommended for the same week, replicated across all invoices in that week.

Then create a running cumulative total of cash outflows (in USD), ordered by when payments are recommended. When payment dates are the same, use invoice_id as a consistent tiebreaker for ordering. Round the cumulative total to 2 decimal places. This helps the finance team see the cash flow impact of the payment schedule.

### 11. Working Capital Impact
Calculate the working capital impact for each invoice:

`working_capital_days` = number of days between invoice_date and recommended_payment_date

`float_benefit_usd` = Calculate the benefit of holding cash using a 5% annual interest rate:
```
float_benefit_usd = amount_usd × (0.05 / 365) × working_capital_days
```
Round to 2 decimal places.

## Data Quality Notes
- Only analyze invoices that have status OPEN or PENDING (ignore PAID, CANCELLED, etc.)
- Round all dollar amounts to 2 decimal places
- Ensure all dates are proper DATE types (not timestamps with time components)
- All monetary columns and scores should use consistent decimal precision
- Handle NULL payment_terms gracefully - treat as having no discount available

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

## Guidelines
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
