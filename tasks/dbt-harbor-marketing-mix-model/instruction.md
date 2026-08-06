# Marketing Mix Modeling (MMM) - Media Effectiveness & Budget Optimization

## Business Context

Build a Marketing Mix Model (MMM) using dbt for a D2C e-commerce company spending $500K/month across multiple marketing channels. The model must:

1. Separate baseline sales from marketing-driven sales
2. Identify saturation points and diminishing returns per channel
3. Provide budget optimization recommendations

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

## dbt Project Setup

**CRITICAL**: Use the existing dbt project based on the database backend:
- DuckDB: `/app/dbt_models_duckdb/`
- Snowflake: `/app/dbt_models_snowflake/`

1. Project already configured with `dbt_project.yml`
2. Add your NEW models to the existing project structure
3. Install dependencies: `dbt deps --profiles-dir .`
4. Run from the project directory: `dbt run --profiles-dir . --select model_name`

**IMPORTANT for Snowflake**: Always use `--select` with specific model names. Never run bare `dbt run` as the pre-built project has thousands of models.

## What is Marketing Mix Modeling?

Unlike attribution models (which track individual customer touchpoints), MMM uses **econometric modeling** to understand:

**1. Baseline Sales** - What you'd sell organically without any marketing

**2. Incremental Sales** - Additional sales driven by marketing spend

**3. Saturation Effects** - Diminishing returns as spend increases

**4. Adstock/Carryover Effects** - Marketing impact persists over time

**5. Cross-Channel Effects** - Channels interact with each other

## Database Environment

The database contains enterprise retail data. Explore it to find the data you need.

**Exploration Commands**:
```sql
-- List all tables
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema != 'information_schema';

-- Examine table structure
DESCRIBE schema_name.table_name;

-- Preview data
SELECT * FROM table_name LIMIT 10;
```

**What you need to discover**:

1. **Sales/Revenue Data**: Find table(s) with daily or transactional sales amounts, channel info, dates, and revenue
2. **Marketing Spend Data**: Find table(s) with daily marketing spend by channel or campaign
3. **Date/Calendar Dimension**: Find table(s) with calendar dates, day of week, holidays, weekends
4. **Channel Reference**: Find how channels are defined and how to normalize them

## Business Requirements

### 1. Baseline Sales Modeling

Separate organic sales from marketing-driven sales:

**Requirements**:
- Calculate baseline sales using historical low-spend periods
- Model day-of-week seasonality (7-day pattern)
- Model monthly seasonality (12-month pattern)
- Identify holiday lift factors
- Baseline should represent "business as usual" without paid media

**Implementation Approach**:
1. Identify "low-spend" days where **total marketing spend across all channels** < $5,000
2. Calculate average daily revenue on those low-spend days (this is your base demand)
3. Apply seasonality: `baseline_revenue = base_demand * baseline_trend * day_factor * month_factor * holiday_factor`
4. **IMPORTANT**: Baseline should typically be 40-60% of total sales

### 2. Adstock Transformation (Carryover Effects)

**Adstock Model**:
- Transform spend data to account for decay over time
- Use geometric adstock: `Adstock_t = Spend_t + (decay_rate * Adstock_t-1)`
- Different channels have different decay rates:
  - **Display ads**: 0.3
  - **Email**: 0.5
  - **TV/Video**: 0.7
  - **Paid search**: 0.1
  - **Social media**: 0.5

### 3. Saturation Curve Modeling

**Saturation Function (Hill Curve)**:
```
Saturated_Impact = Spend^alpha / (Spend^alpha + halfpoint^alpha)
```

**Channel Saturation Parameters**:
- **Display Ads**: halfpoint = $15K/month, alpha = 1.5
- **Email**: halfpoint = $80K/month, alpha = 2.0
- **Paid Search**: halfpoint = $20K/month, alpha = 1.6
- **Social Media**: halfpoint = $40K/month, alpha = 1.4
- **TV/Video**: halfpoint = $60K/month, alpha = 1.8

**Requirements**:
- Convert monthly halfpoints to daily before applying the curve: `halfpoint_daily = halfpoint_monthly / 30`
- Calculate `saturated_spend = Saturated_Impact * adstock_spend`
- Calculate `saturation_efficiency_pct = 100 * saturated_spend / NULLIF(adstock_spend, 0)` (cap 0-100)

### 4. Incremental Revenue Attribution

**Channel Response Coefficients** (Revenue per $1 saturated spend):
- **Email**: $4.50
- **Paid Search**: $3.80
- **Social Media**: $3.20
- **Display Ads**: $2.80
- **TV/Video**: $2.50

### 5. Channel Effectiveness & ROI Analysis

**Classification Rules**:
- **Under-invested**: spend ratio < 0.7
- **Optimal**: spend ratio 0.7-1.3
- **Over-saturated**: spend ratio > 1.3

### 6. Budget Optimization Recommendations

**Constraints**:
- Total budget remains constant ($500K/month)
- Minimum spend per channel: $20K/month
- Maximum spend per channel: $200K/month

### 7. Time-Series Decomposition

Break down daily sales into components:
```
Actual_Sales = Baseline + Email_Incremental + Paid_Search_Incremental +
               Social_Incremental + Display_Incremental + TV_Incremental + Residual
```

## Required Models

Create the following dbt models organized by layer:

### Staging Layer (schema: `main_staging`)

Create staging models in `models/staging/mmm/`:

**1. `stg_mmm__daily_sales`**
- Grain: One row per (date, channel)
- Required columns: `metric_date`, `channel_id`, `channel_name`, `total_revenue`, `order_count`, `units_sold`

**2. `stg_mmm__marketing_spend`**
- Grain: One row per (date, channel)
- Required columns: `metric_date`, `channel_id`, `channel_name`, `spend_amount`, `impressions`, `clicks`

**3. `stg_mmm__calendar`**
- Grain: One row per date
- Required columns: `metric_date`, `day_of_week`, `day_name`, `month`, `quarter`, `is_weekend`, `is_holiday`, `holiday_name`

**4. `stg_mmm__channel_mapping`**
- Grain: One row per channel
- Required columns: `channel_id`, `channel_name`, `channel_type`, `decay_rate`, `saturation_halfpoint`, `saturation_shape`, `saturation_alpha`

**Channel Mapping Rule (Required)**:
Normalize all channel names to exactly 5 canonical values: Email, Paid Search, Social Media, Display Ads, TV/Video. Use case-insensitive matching.

### Intermediate Layer (schema: `main_intermediate`)

Create intermediate models in `models/intermediate/mmm/`:

**5. `int_mmm__baseline_sales`**
- Grain: One row per date
- Required columns: `metric_date`, `baseline_revenue`, `baseline_trend`, `day_of_week_factor`, `month_factor`, `holiday_lift_factor`, `is_weekend`, `is_holiday`

**6. `int_mmm__adstock_transformed`**
- Grain: One row per (date, channel)
- Required columns: `metric_date`, `channel_id`, `channel_name`, `raw_spend`, `decay_rate`, `adstock_spend`, `cumulative_adstock_7d`, `cumulative_adstock_30d`

**7. `int_mmm__saturation_curves`**
- Grain: One row per (date, channel)
- Required columns: `metric_date`, `channel_id`, `channel_name`, `adstock_spend`, `saturation_halfpoint`, `saturation_alpha`, `saturated_spend`, `saturation_efficiency_pct`, `saturation_status`

**8. `int_mmm__incremental_revenue`**
- Grain: One row per (date, channel)
- Required columns: `metric_date`, `channel_id`, `channel_name`, `saturated_spend`, `channel_coefficient`, `incremental_revenue`, `raw_roas`, `effective_roas`

**9. `int_mmm__daily_decomposition`**
- Grain: One row per date
- Required columns: `metric_date`, `actual_sales`, `baseline_sales`, `email_incremental`, `paid_search_incremental`, `social_incremental`, `display_incremental`, `tv_incremental`, `total_incremental`, `model_predicted_sales`, `residual`, `residual_pct`

### Marts Layer (schema: `main_marts`)

Create mart models in `models/marts/mmm/`:

**10. `fct_mmm_performance`**
- Grain: One row per (date, channel)
- Required columns: `metric_date`, `channel_id`, `channel_name`, `raw_spend`, `adstock_spend`, `saturated_spend`, `incremental_revenue`, `raw_roas`, `effective_roas`, `saturation_efficiency_pct`, `contribution_to_total_sales_pct`

**11. `rpt_mmm_channel_effectiveness`**
- Grain: One row per channel
- Required columns: `channel_id`, `channel_name`, `channel_type`, `total_raw_spend`, `total_incremental_revenue`, `avg_saturation_efficiency_pct`, `raw_roas`, `marginal_roas`, `saturation_status`, `rank_by_effectiveness`, `recommended_action`

**12. `rpt_mmm_budget_optimization`**
- Grain: One row per channel
- Required columns: `channel_id`, `channel_name`, `current_budget`, `current_budget_pct`, `current_marginal_roas`, `recommended_budget`, `recommended_budget_pct`, `budget_change`, `budget_change_pct`, `expected_revenue_change`

**13. `rpt_mmm_decomposition`**
- Grain: One row per date
- Required columns: `metric_date`, `actual_sales`, `baseline_sales`, `baseline_pct`, `email_incremental`, `email_pct`, `paid_search_incremental`, `paid_search_pct`, `social_incremental`, `social_pct`, `display_incremental`, `display_pct`, `tv_incremental`, `tv_pct`, `total_marketing_incremental`, `marketing_pct`, `residual`, `residual_pct`

**Percentage column formulas (all on a 0–100 scale; this `rpt_mmm_decomposition` table only):**
- `baseline_pct       = 100.0 * baseline_sales / NULLIF(actual_sales, 0)`
- `email_pct          = 100.0 * email_incremental / NULLIF(actual_sales, 0)`
- `paid_search_pct    = 100.0 * paid_search_incremental / NULLIF(actual_sales, 0)`
- `social_pct         = 100.0 * social_incremental / NULLIF(actual_sales, 0)`
- `display_pct        = 100.0 * display_incremental / NULLIF(actual_sales, 0)`
- `tv_pct             = 100.0 * tv_incremental / NULLIF(actual_sales, 0)`
- `marketing_pct      = 100.0 * total_marketing_incremental / NULLIF(actual_sales, 0)`
- `residual_pct       = 100.0 * residual / NULLIF(actual_sales, 0)`

`baseline_pct + marketing_pct + residual_pct` should sum to ~100 per row.

**14. `rpt_mmm_saturation_analysis`**
- Grain: One row per channel
- Required columns: `channel_id`, `channel_name`, `current_spend_level`, `saturation_halfpoint`, `spend_vs_halfpoint_ratio`, `current_efficiency_pct`, `optimal_spend_level`, `spend_gap`, `is_oversaturated`

**15. `rpt_mmm_summary`**
- Grain: One row per time period (week)
- Required columns: `time_period`, `total_sales`, `baseline_sales`, `baseline_pct`, `total_marketing_incremental`, `marketing_pct`, `total_marketing_spend`, `overall_marketing_roas`, `avg_saturation_efficiency_pct`, `top_performing_channel`, `most_saturated_channel`

## Implementation Requirements

### Data Alignment (Required)
- Use the **overlap date range** where both sales and marketing spend exist.

### Business Logic

**Baseline Calculation**:
- Apply day-of-week factors: Monday (0.85), Tuesday-Thursday (1.0), Friday (1.05), Weekend (0.95)
- Apply month factors: Jan (0.90), Feb (0.92), Mar (0.95), Apr (0.98), May (1.00), Jun (1.02), Jul (1.03), Aug (1.02), Sep (1.00), Oct (1.03), Nov (1.05), Dec (1.20)
- Holiday lift: 1.15x multiplier
- Trend: 2% monthly growth compounded from first date

**Adstock Formula**: `Adstock(t) = Spend(t) + decay_rate * Adstock(t-1)`

**Saturation Formula (Hill Curve)**:
```
Saturated = (Adstock^alpha) / (Adstock^alpha + halfpoint^alpha)
Saturated_Spend = Saturated * Adstock
```

**Incremental Revenue**: `Incremental(channel, date) = channel_coefficient * saturated_spend(channel, date)`

### Schema Configuration

```sql
-- For staging models:
{{ config(materialized='view', schema='staging') }}

-- For intermediate models:
{{ config(materialized='view', schema='intermediate') }}

-- For marts models:
{{ config(materialized='table', schema='marts') }}
```

The dbt project has `target_schema='main'`. When you set `schema='staging'`, dbt creates `main_staging`.

### Data Quality
- Handle dates with zero marketing spend
- Prevent division by zero in ROAS calculations
- Ensure saturation efficiency stays between 0-100%

## Guidelines

- Use `{{ source() }}` for raw tables and `{{ ref() }}` for model dependencies
- Staging = views, Intermediate = views, Marts = tables
