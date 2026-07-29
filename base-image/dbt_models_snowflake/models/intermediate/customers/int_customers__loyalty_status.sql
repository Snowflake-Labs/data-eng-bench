{{
    config(
        materialized='view',
        tags=['intermediate', 'customers']
    )
}}

/*
 * Customer loyalty program tier and status
 * Determines tier based on spend and frequency
 */

with customer_metrics as (
    select
        customer_id,
        lifetime_revenue,
        total_orders,
        successful_orders,
        first_order_date,
        last_order_date,
        purchase_frequency_per_month
    from {{ ref('int_customers__lifetime_metrics') }}
),

loyalty_tiers as (
    select
        customer_id,
        lifetime_revenue,
        total_orders,
        successful_orders,
        first_order_date,
        last_order_date,
        purchase_frequency_per_month,
        DATEDIFF(month, first_order_date, current_date) as months_as_customer,
        -- Loyalty points calculation (1 point per dollar + bonus for frequency)
        round(lifetime_revenue + (successful_orders * 10)) as loyalty_points,
        -- Tier assignment
        case
            when lifetime_revenue >= 10000 and successful_orders >= 20 then 'Platinum'
            when lifetime_revenue >= 5000 and successful_orders >= 10 then 'Gold'
            when lifetime_revenue >= 1000 and successful_orders >= 5 then 'Silver'
            when successful_orders >= 1 then 'Bronze'
            else 'None'
        end as loyalty_tier,
        -- Benefits multiplier
        case
            when lifetime_revenue >= 10000 and successful_orders >= 20 then 1.20
            when lifetime_revenue >= 5000 and successful_orders >= 10 then 1.15
            when lifetime_revenue >= 1000 and successful_orders >= 5 then 1.10
            when successful_orders >= 1 then 1.05
            else 1.00
        end as points_multiplier,
        -- Tier eligibility for upgrade
        case
            when lifetime_revenue >= 10000 then 'Platinum - Maximum Tier'
            when lifetime_revenue >= 4000 then 'Close to Gold'
            when lifetime_revenue >= 800 then 'Close to Silver'
            else 'Keep Shopping'
        end as tier_progress
    from customer_metrics
)

select * from loyalty_tiers
