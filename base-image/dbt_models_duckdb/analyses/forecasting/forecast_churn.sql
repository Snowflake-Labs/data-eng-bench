-- Customer Churn Forecasting
-- Predicts customer churn risk based on behavior patterns

with customer_activity as (
    select
        customer_id,
        max(order_date) as last_order_date,
        min(order_date) as first_order_date,
        count(distinct order_id) as total_orders,
        sum(line_total) as lifetime_value,
        date_diff('day', max(order_date), current_date) as days_since_last_order,
        date_diff('day', min(order_date), max(order_date)) as customer_lifespan_days
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by customer_id
),

churn_indicators as (
    select
        customer_id,
        last_order_date,
        first_order_date,
        total_orders,
        lifetime_value,
        days_since_last_order,
        customer_lifespan_days,
        case
            when customer_lifespan_days > 0
            then round(total_orders::decimal / (customer_lifespan_days / 30.0), 2)
            else 0
        end as avg_orders_per_month,
        -- Churn risk score (0-100)
        least(100, (
            case when days_since_last_order > 90 then 40
                 when days_since_last_order > 60 then 25
                 when days_since_last_order > 30 then 10
                 else 0
            end +
            case when total_orders < 2 then 30
                 when total_orders < 5 then 15
                 else 0
            end +
            case when lifetime_value < 100 then 30
                 when lifetime_value < 500 then 15
                 else 0
            end
        )) as churn_risk_score
    from customer_activity
),

churn_classification as (
    select
        customer_id,
        last_order_date,
        days_since_last_order,
        total_orders,
        round(lifetime_value, 2) as lifetime_value,
        avg_orders_per_month,
        churn_risk_score,
        case
            when churn_risk_score >= 70 then 'High Risk - Immediate Action'
            when churn_risk_score >= 50 then 'Medium Risk - Engage'
            when churn_risk_score >= 30 then 'Low Risk - Monitor'
            else 'Active'
        end as churn_risk_category,
        case
            when days_since_last_order > 90 then 'Churned'
            when days_since_last_order > 60 then 'At Risk'
            when days_since_last_order > 30 then 'Cooling'
            else 'Active'
        end as customer_status
    from churn_indicators
)

select * from churn_classification
order by churn_risk_score desc
