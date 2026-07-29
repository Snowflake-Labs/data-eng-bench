{{
    config(
        materialized='view',
        tags=['intermediate', 'products']
    )
}}

-- int_products__lifecycle_stage
-- Product lifecycle classification based on sales trends
-- Author: Dr. Emily Watson (Data Science)
--
-- Methodology: Implements standard product lifecycle curve analysis
-- Reference: Kotler, P. "Marketing Management" (15th ed.), Chapter 11
--
-- The lifecycle_stage classification uses trailing 3-month sales trends
-- to categorize products into: Introduction, Growth, Maturity, Decline, EOL
--
-- TODO: Add seasonality adjustment (Christmas products look like "decline" in Jan)
-- TODO: Consider adding smoothing to handle promotional spikes
-- FIXME: New products without 3 months history get incorrect classification

with product_sales_trend as (
    select
        product_id,
        DATE_TRUNC('month', order_date) as sales_month,
        sum(quantity_ordered) as monthly_units_sold,
        sum(line_total) as monthly_revenue
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by product_id, DATE_TRUNC('month', order_date)
),

recent_trends as (
    select
        product_id,
        max(case when sales_month = DATE_TRUNC('month', DATEADD(month, -1, current_date)) then monthly_units_sold else 0 end) as units_last_month,
        max(case when sales_month = DATE_TRUNC('month', DATEADD(month, -2, current_date)) then monthly_units_sold else 0 end) as units_2_months_ago,
        max(case when sales_month = DATE_TRUNC('month', DATEADD(month, -3, current_date)) then monthly_units_sold else 0 end) as units_3_months_ago,
        min(sales_month) as first_sale_month,
        max(sales_month) as last_sale_month
    from product_sales_trend
    group by product_id
),

lifecycle_calc as (
    select
        product_id,
        units_last_month,
        units_2_months_ago,
        units_3_months_ago,
        first_sale_month,
        last_sale_month,
        DATEDIFF(month, first_sale_month, current_date) as months_since_launch,
        DATEDIFF(month, last_sale_month, current_date) as months_since_last_sale,
        case
            when units_last_month > units_2_months_ago and units_2_months_ago > units_3_months_ago then 'Growth'
            when units_last_month < units_2_months_ago and units_2_months_ago < units_3_months_ago then 'Decline'
            when units_last_month = 0 and units_2_months_ago = 0 then 'Discontinued'
            else 'Mature'
        end as trend_direction,
        case
            when DATEDIFF(month, first_sale_month, current_date) <= 3 then 'Introduction'
            when units_last_month > units_2_months_ago and units_2_months_ago > units_3_months_ago then 'Growth'
            when units_last_month < units_2_months_ago and units_2_months_ago < units_3_months_ago then 'Decline'
            when DATEDIFF(month, last_sale_month, current_date) > 6 then 'End of Life'
            else 'Maturity'
        end as lifecycle_stage
    from recent_trends
)

select * from lifecycle_calc
