{{
    config(
        materialized='view',
        tags=['intermediate', 'customers']
    )
}}

/*
================================================================================
int_customers__lifetime_metrics

Customer Lifetime Value (CLV/LTV) calculations and derived metrics.

Methodology:
  Simple historical CLV calculation based on past purchases.
  predicted_ltv uses naive 2x multiplier (industry average for 3yr horizon).

  For more sophisticated CLV modeling, see:
  - Fader & Hardie (2005) "RFM and CLV: Using Iso-Value Curves for Customer Base Analysis"
  - The company's Data Science team is working on a proper BG/NBD model (Q2 2025)

Author: Dr. Emily Watson (Data Science)
Modified: 2024-06-15

Performance: 3 min, aggregates from fct_sales (~50M rows)
Memory: 64GB

ISSUES:
- predicted_ltv = revenue * 2 is a PLACEHOLDER. Don't use for actual forecasting.
- Cancellations reduce order count but not revenue (refunds handled separately)
- First/last order dates don't account for timezone issues
================================================================================
*/

-- TODO: Replace simple LTV with probabilistic model (BG/NBD)
-- TODO: Add customer cohort for cohort-based CLV analysis
-- TODO: Factor in customer acquisition cost for true CLV
-- FIXME: lifetime_revenue should subtract refunds
-- HACK: predicted_ltv = revenue * 2 is embarrassingly simple but "good enough" for now

with customer_sales as (
    select
        customer_id,
        min(order_date) as first_order_date,
        max(order_date) as last_order_date,
        count(distinct order_id) as total_orders,
        count(distinct case when is_cancelled = false then order_id end) as successful_orders,
        sum(case when is_cancelled = false then line_total else 0 end) as lifetime_revenue,
        sum(case when is_cancelled = false then quantity_ordered else 0 end) as total_units_purchased,
        avg(case when is_cancelled = false then line_total end) as avg_order_value,
        DATEDIFF(day, min(order_date), max(order_date)) as customer_lifespan_days
    from {{ ref('fct_sales') }}
    where customer_id is not null
    group by customer_id
),

metrics as (
    select
        customer_id,
        first_order_date,
        last_order_date,
        total_orders,
        successful_orders,
        lifetime_revenue,
        total_units_purchased,
        round(avg_order_value, 2) as avg_order_value,
        customer_lifespan_days,
        -- Purchase frequency (orders per month)
        case
            when customer_lifespan_days > 0
            then round(successful_orders::decimal / (customer_lifespan_days::decimal / 30.0), 2)
            else 0
        end as purchase_frequency_per_month,
        -- Predicted LTV - multiplier is now configurable (see dbt_project.yml)
        -- NOTE: Still a placeholder calculation - see HACK comment above
        round(lifetime_revenue * {{ var('ltv_prediction_multiplier', 2.0) }}, 2) as predicted_ltv,
        -- Customer segment based on LTV (thresholds configurable via vars)
        case
            when lifetime_revenue >= {{ var('customer_value_vip_threshold', 10000) }} then 'VIP'
            when lifetime_revenue >= {{ var('customer_value_high_threshold', 5000) }} then 'High Value'
            when lifetime_revenue >= {{ var('customer_value_medium_threshold', 1000) }} then 'Medium Value'
            when lifetime_revenue >= 100 then 'Low Value'  -- TODO: Move to var
            else 'Minimal Value'
        end as ltv_segment
    from customer_sales
)

select * from metrics
