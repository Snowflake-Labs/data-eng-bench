# RFM Customer Segmentation with Dynamic Tiering, Revenue Attribution, and Predictive Scoring

Build a dbt project that performs advanced RFM (Recency, Frequency, Monetary) customer segmentation, calculates dynamic tier transitions, attributes revenue across customer segments with time-weighted scoring, and implements predictive customer health metrics with cohort analysis.

## Data

The following staging tables already exist in the database and should be referenced directly in your models:

- `stg_analytics__fact_sales` - customer order transactions with sale keys, date keys, customer keys, channel keys, order IDs, quantities, amounts, and status fields. Explore the table to understand available columns.
- `stg_analytics__dim_customer` - customer dimension with keys and segmentation fields. Explore to find relevant columns for customer mapping.
- `stg_customer__customers` - customer master data including acquisition dates and tier information. Explore to understand the schema.
- `stg_customer__customer_tiers` - tier qualification thresholds with tier levels and requirements. Explore for tier assignment logic.
- `stg_analytics__dim_channel` - channel information with channel types. Explore for channel attribution logic.

**Important**: These staging tables are pre-loaded in the database. Do not create seeds or staging models for them. Reference them directly using `{{ ref('stg_analytics__fact_sales') }}`, etc.

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

## Project Setup

A dbt project already exists with pre-configured staging models:

- DuckDB: `/app/dbt_models_duckdb`
- Snowflake: `/app/dbt_models_snowflake`

All the required staging models are already implemented and available for use.

**Important**: Add your models to the existing dbt project. Do NOT create a new standalone dbt project.

## Required Models

Create the following models in the existing project under `models/marts/`:

**Marts** (`models/marts/`):
- `customer_rfm_scores.sql` - RFM calculation and composite scoring with health metrics
- `customer_tier_transitions.sql` - tier movement analysis with velocity metrics
- `channel_revenue_attribution.sql` - weighted revenue distribution across channels
- `customer_cohort_analysis.sql` - cohort-based retention and value analysis

## Output Requirements

### customer_rfm_scores must contain:
- `customer_id` - unique customer identifier
- `analysis_date` - reference date for analysis (2024-12-31)
- `first_order_date` - date of customer's first order
- `last_order_date` - date of customer's most recent order
- `recency_days` - days since last order (integer)
- `frequency` - total number of completed orders (integer)
- `monetary` - total revenue from completed orders, rounded to 2 decimals
- `avg_order_value` - average order value, rounded to 2 decimals
- `recency_score` - recency quintile (1-5, where 5 is most recent)
- `frequency_score` - frequency quintile (1-5, where 5 is most frequent)
- `monetary_score` - monetary quintile (1-5, where 5 is highest spend)
- `rfm_score` - weighted composite score: (R*0.35 + F*0.25 + M*0.40), rounded to 2 decimals
- `rfm_segment` - customer segment label (see Business Rules)
- `assigned_tier` - tier assignment based on rfm_score matching tier_rules
- `customer_lifetime_days` - days from signup to analysis_date (integer)
- `orders_per_month` - frequency / (customer_lifetime_days / 30.0), rounded to 4 decimals
- `revenue_velocity` - monetary / (customer_lifetime_days / 30.0), rounded to 2 decimals
- `customer_health_score` - composite health metric (0-100 scale, see Business Rules), rounded to 2 decimals
- `predicted_churn_risk` - probability of churn (0.00-1.00), rounded to 2 decimals
- `expected_next_order_days` - predicted days until next order (integer), based on average order frequency
- `lifetime_value_estimate` - estimated total lifetime value (see Business Rules), rounded to 2 decimals

### customer_tier_transitions must contain:
- `customer_id` - unique customer identifier
- `current_tier` - tier as of analysis_date
- `previous_tier` - tier based on orders from 90+ days ago (null if new customer)
- `tier_direction` - 'upgrade', 'downgrade', 'stable', or 'new'
- `transition_score_delta` - difference in rfm_score (current - previous), rounded to 2 decimals
- `days_in_current_tier` - estimated days in current tier (integer)
- `at_risk_flag` - boolean: true if recency_days > 60 AND tier_direction in ('downgrade', 'stable')
- `momentum_score` - weighted score indicating trajectory (see Business Rules), rounded to 2 decimals
- `projected_next_tier` - predicted tier in 90 days based on momentum (see Business Rules)
- `intervention_priority` - 'critical', 'high', 'medium', 'low' based on at_risk and tier value
- `tier_stability_index` - measure of tier consistency over time (0-100), rounded to 2 decimals
- `upgrade_probability` - likelihood of upgrade in next 90 days (0.00-1.00), rounded to 2 decimals
- `recommended_action` - specific action recommendation based on customer status (see Business Rules)

### channel_revenue_attribution must contain:

**Important**: Only include channels that had at least one completed order in the current year (2024). Exclude channels with no orders in 2024.

- `channel` - sales channel name
- `attributed_orders` - count of orders (integer)
- `raw_revenue` - sum of order totals, rounded to 2 decimals
- `weighted_revenue` - revenue * channel weight, rounded to 2 decimals
- `revenue_share_pct` - percentage of total weighted revenue, rounded to 2 decimals
- `unique_customers` - distinct customer count (integer)
- `avg_customer_value` - raw_revenue / unique_customers, rounded to 2 decimals
- `channel_efficiency` - weighted_revenue / attributed_orders, rounded to 2 decimals
- `yoy_growth_rate` - year-over-year growth percentage (see Business Rules), rounded to 2 decimals
- `channel_rank` - rank by weighted_revenue descending (integer)
- `customer_acquisition_rate` - percentage of first-time buyers through this channel, rounded to 2 decimals
- `repeat_purchase_rate` - percentage of customers who made repeat purchases, rounded to 2 decimals
- `avg_basket_size` - average number of items per order, rounded to 2 decimals
- `channel_contribution_margin` - weighted_revenue minus channel costs as percentage (see Business Rules), rounded to 2 decimals

### customer_cohort_analysis must contain:
- `cohort_month` - month of customer acquisition (YYYY-MM format as string)
- `cohort_size` - number of customers acquired in that cohort (integer)
- `months_since_acquisition` - number of months since cohort start (integer, 0-indexed)
- `active_customers` - customers who made a purchase in that period (integer)
- `retention_rate` - percentage of cohort still active, rounded to 2 decimals
- `cohort_revenue` - total revenue from cohort in that period, rounded to 2 decimals
- `cumulative_revenue` - running total of cohort revenue, rounded to 2 decimals
- `avg_revenue_per_customer` - cohort_revenue / active_customers, rounded to 2 decimals
- `orders_count` - total orders from cohort in that period (integer)
- `avg_order_frequency` - orders_count / active_customers, rounded to 2 decimals
- `churn_rate` - percentage of cohort lost compared to previous period, rounded to 2 decimals
- `cohort_ltv` - cumulative_revenue / cohort_size, rounded to 2 decimals

## Business Rules

### 1. RFM Quintile Scoring
Calculate quintiles using NTILE(5) with the following logic:
- **Recency**: Lower days = higher score (invert the quintile: 6 - NTILE value)
- **Frequency**: Higher count = higher score (direct NTILE)
- **Monetary**: Higher value = higher score (direct NTILE)

Handle edge cases:
- Customers with only 1 order should receive frequency_score = 1
- Customers with $0 monetary value should receive monetary_score = 1
- If NTILE produces fewer than 5 groups due to data sparsity, distribute evenly

### 2. RFM Segment Labels
Assign `rfm_segment` based on the combination of R, F, M scores:
```
Champions:        R >= 4 AND F >= 4 AND M >= 4
Loyal Customers:  F >= 4 AND M >= 3
Potential Loyalists: R >= 4 AND F >= 2 AND F <= 4
Recent Customers: R >= 4 AND F = 1
Promising:        R >= 3 AND F >= 2 AND M >= 2
Needs Attention:  R >= 2 AND R <= 3 AND F >= 2
About to Sleep:   R = 2 AND F <= 2
At Risk:          R <= 2 AND F >= 3
Cant Lose:        R <= 2 AND F >= 4 AND M >= 4
Lost:             R = 1 AND F = 1
Hibernating:      R <= 2 AND F <= 2
```
Apply rules in order; first match wins. Default to 'Other' if no match.

### 3. Tier Assignment
Match `rfm_score` to `stg_customer__customer_tiers` using tier_level ordering:
- Diamond (level 5): rfm_score >= 4.2
- Platinum (level 4): rfm_score >= 3.5 AND < 4.2
- Gold (level 3): rfm_score >= 2.8 AND < 3.5
- Silver (level 2): rfm_score >= 2.0 AND < 2.8
- Bronze (level 1): rfm_score >= 1.0 AND < 2.0
- If no tier matches, assign 'Standard'

### 4. Previous Tier Calculation
To calculate `previous_tier`:
- Recalculate RFM scores using ONLY orders placed MORE THAN 90 days before analysis_date
- If customer had no orders before 90 days ago, previous_tier is NULL
- Apply the same tier assignment logic to the recalculated score

### 5. Momentum Score
Calculate `momentum_score` using this formula:
```
base_momentum = transition_score_delta * 10

recency_factor = CASE
    WHEN recency_days <= 14 THEN 1.5
    WHEN recency_days <= 30 THEN 1.2
    WHEN recency_days <= 60 THEN 1.0
    WHEN recency_days <= 90 THEN 0.7
    ELSE 0.4
END

frequency_boost = CASE
    WHEN orders_in_last_90_days >= 5 THEN 1.3
    WHEN orders_in_last_90_days >= 3 THEN 1.15
    WHEN orders_in_last_90_days >= 1 THEN 1.0
    ELSE 0.6
END

momentum_score = base_momentum * recency_factor * frequency_boost
```
Clamp the result between -10.0 and 10.0.

### 6. Projected Next Tier
Based on `momentum_score`:
- If momentum_score >= 2.0: project upgrade to next higher tier
- If momentum_score <= -2.0: project downgrade to next lower tier
- Otherwise: project same as current_tier
- Tier order (low to high): Bronze -> Silver -> Gold -> Platinum -> Diamond
- Cannot project below Bronze or above Diamond

### 7. Intervention Priority
Assign priority based on:
```
critical: at_risk_flag = true AND current_tier IN ('Diamond', 'Platinum')
high:     at_risk_flag = true AND current_tier IN ('Gold')
medium:   at_risk_flag = true AND current_tier IN ('Silver')
          OR (tier_direction = 'downgrade' AND NOT at_risk_flag)
low:      all other cases
```

### 8. Year-over-Year Growth
For `yoy_growth_rate`:
- Current period: orders with order_date in 2024
- Previous period: orders with order_date in 2023
- Formula: ((current_revenue - previous_revenue) / previous_revenue) * 100
- If previous_revenue = 0, set yoy_growth_rate to NULL
- Only include completed orders (status = 'completed' or similar indicator)

### 9. Channel Weight Attribution
The `weighted_revenue` is calculated as:
```
weighted_revenue = raw_revenue * weight
```
Where `weight` is derived from channel type: 'Online' = 1.2, 'Store' = 1.0, 'Partner' = 0.8. Default weight = 1.0.

### 10. Customer Health Score
Calculate `customer_health_score` on a 0-100 scale using this formula:
```
base_score = rfm_score * 20  (converts 1-5 scale to 20-100)

recency_adjustment = CASE
    WHEN recency_days <= 30 THEN 1.0
    WHEN recency_days <= 60 THEN 0.9
    WHEN recency_days <= 90 THEN 0.7
    WHEN recency_days <= 180 THEN 0.5
    ELSE 0.3
END

frequency_adjustment = CASE
    WHEN orders_per_month >= 2.0 THEN 1.1
    WHEN orders_per_month >= 1.0 THEN 1.0
    WHEN orders_per_month >= 0.5 THEN 0.9
    ELSE 0.8
END

customer_health_score = base_score * recency_adjustment * frequency_adjustment
```
Clamp the result between 0 and 100.

### 11. Predicted Churn Risk
Calculate `predicted_churn_risk` as probability (0.00 to 1.00):
```
base_risk = CASE rfm_segment
    WHEN 'Lost' THEN 0.95
    WHEN 'Hibernating' THEN 0.85
    WHEN 'At Risk' THEN 0.75
    WHEN 'About to Sleep' THEN 0.65
    WHEN 'Cant Lose' THEN 0.60
    WHEN 'Needs Attention' THEN 0.45
    WHEN 'Promising' THEN 0.30
    WHEN 'Potential Loyalists' THEN 0.20
    WHEN 'Recent Customers' THEN 0.25
    WHEN 'Loyal Customers' THEN 0.15
    WHEN 'Champions' THEN 0.05
    ELSE 0.50
END

recency_modifier = CASE
    WHEN recency_days > 180 THEN 0.20
    WHEN recency_days > 90 THEN 0.10
    WHEN recency_days > 60 THEN 0.05
    ELSE 0.0
END

predicted_churn_risk = LEAST(1.0, base_risk + recency_modifier)
```

### 12. Expected Next Order Days
Calculate `expected_next_order_days` based on customer's average purchase interval:
```
avg_days_between_orders = customer_lifetime_days / GREATEST(frequency - 1, 1)
expected_next_order_days = GREATEST(0, avg_days_between_orders - recency_days)
```
Round to nearest integer. If result is negative, set to 0.

### 13. Lifetime Value Estimate
Calculate `lifetime_value_estimate` using:
```
monthly_value = revenue_velocity
expected_remaining_months = CASE
    WHEN predicted_churn_risk >= 0.8 THEN 3
    WHEN predicted_churn_risk >= 0.6 THEN 6
    WHEN predicted_churn_risk >= 0.4 THEN 12
    WHEN predicted_churn_risk >= 0.2 THEN 24
    ELSE 36
END

lifetime_value_estimate = monetary + (monthly_value * expected_remaining_months * (1 - predicted_churn_risk))
```

### 14. Tier Stability Index
Calculate `tier_stability_index` (0-100) measuring tier consistency:
```
base_stability = CASE
    WHEN tier_direction = 'new' THEN 50.0
    WHEN tier_direction = 'stable' AND recency_days <= 30 THEN 100.0
    WHEN tier_direction = 'stable' AND recency_days <= 60 THEN 85.0
    WHEN tier_direction = 'stable' THEN 70.0
    WHEN tier_direction = 'upgrade' THEN 80.0
    WHEN tier_direction = 'downgrade' AND ABS(transition_score_delta) < 0.5 THEN 50.0
    WHEN tier_direction = 'downgrade' THEN 30.0
    ELSE 50.0
END

order_adjustment = CASE
    WHEN orders_in_last_90_days >= 3 THEN 10
    WHEN orders_in_last_90_days >= 1 THEN 0
    ELSE -20
END

tier_stability_index = GREATEST(0, LEAST(100, base_stability + order_adjustment))
```

### 15. Upgrade Probability
Calculate `upgrade_probability` (0.00-1.00) for upgrade likelihood in next 90 days:
```
base_probability = CASE
    WHEN momentum_score >= 5.0 THEN 0.80
    WHEN momentum_score >= 3.0 THEN 0.60
    WHEN momentum_score >= 2.0 THEN 0.45
    WHEN momentum_score >= 1.0 THEN 0.30
    WHEN momentum_score >= 0.0 THEN 0.15
    ELSE 0.05
END

tier_ceiling_factor = CASE current_tier
    WHEN 'Diamond' THEN 0.0  -- Cannot upgrade further
    WHEN 'Platinum' THEN 0.7
    WHEN 'Gold' THEN 0.85
    WHEN 'Silver' THEN 0.95
    WHEN 'Bronze' THEN 1.0
    ELSE 1.0
END

upgrade_probability = base_probability * tier_ceiling_factor
```

### 16. Recommended Action
Assign `recommended_action` based on customer status:
```
'immediate_outreach': at_risk_flag = true AND current_tier IN ('Diamond', 'Platinum')
'win_back_campaign': rfm_segment IN ('Lost', 'Hibernating')
'loyalty_program_upgrade': tier_direction = 'upgrade' AND momentum_score >= 2.0
'retention_offer': at_risk_flag = true AND current_tier IN ('Gold', 'Silver')
'engagement_program': rfm_segment IN ('Needs Attention', 'About to Sleep')
'vip_treatment': rfm_segment = 'Champions'
'nurture_sequence': rfm_segment IN ('Recent Customers', 'Potential Loyalists')
'standard_marketing': all other cases
```
Apply rules in order; first match wins.

### 17. Channel Acquisition Rate
Calculate `customer_acquisition_rate` per channel:
```
first_orders_via_channel = COUNT of orders that are the customer's first order ever AND occurred in 2024
customer_acquisition_rate = (first_orders_via_channel / total_first_orders_all_channels) * 100
```
**Important**: Count only first orders that occurred in 2024. The `customer_acquisition_rate` should represent the share of 2024 first-time customer orders acquired through each channel. This metric focuses on customer acquisition performance during the current year (2024), not historical first orders from previous years.

### 18. Repeat Purchase Rate
Calculate `repeat_purchase_rate` per channel:
```
customers_with_repeat = COUNT DISTINCT customers with more than 1 order via this channel
repeat_purchase_rate = (customers_with_repeat / unique_customers) * 100
```

### 19. Channel Contribution Margin
Calculate `channel_contribution_margin`:
```
channel_cost_factor = CASE channel_type
    WHEN 'Online' THEN 0.15  -- 15% cost
    WHEN 'Store' THEN 0.25   -- 25% cost
    WHEN 'Partner' THEN 0.35 -- 35% cost
    ELSE 0.20
END

channel_contribution_margin = ((weighted_revenue - (raw_revenue * channel_cost_factor)) / weighted_revenue) * 100
```

### 20. Cohort Analysis Rules
For `customer_cohort_analysis`:
- Group customers by acquisition month (from `acquisition_date`)
- Track activity for each cohort across subsequent months up to analysis_date
- `months_since_acquisition` = 0 for the acquisition month, 1 for next month, etc.
- A customer is "active" in a month if they placed at least one order
- `retention_rate` = (active_customers / cohort_size) * 100
- `churn_rate` for month M = ((active_in_M-1 - active_in_M) / active_in_M-1) * 100
  - For month 0, churn_rate = 0
  - If active_in_M-1 = 0, churn_rate = 0
  - If active_customers increases compared to previous month (customer re-activation), clamp churn_rate to 0 using GREATEST(0, calculated_value)
- Include cohorts from the last 12 months before analysis_date
- `cumulative_revenue` is the running sum of `cohort_revenue` from month 0 to current month

## Notes
- Analysis reference date is **2024-12-31**
- Only include completed orders in all RFM calculations (filter where `total_amount > 0` to exclude cancelled/refunded orders)
- Customers with zero completed orders should not appear in outputs
- All monetary values are in USD
- Handle NULL values gracefully - treat missing dates as exclusions
- Convert DATE_KEY (integer YYYYMMDD) to proper dates
- For NTILE functions, include ORDER BY customer_id as tie-breaker to ensure deterministic results

If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
