-- Revenue by Payment Method Report
-- Monthly breakdown of revenue collection by payment method, including
-- success rates, transaction averages, and relative market share

with payments as (
    select * from {{ ref('stg_finance__customer_payments') }}
),

-- Aggregate payments by month and method
monthly_stats as (
    select
        payment_method,
        DATE_TRUNC('month', payment_date) as payment_month,
        count(distinct payment_id) as total_transactions,
        count(distinct case when status = 'SUCCESS' then payment_id end) as successful_transactions,
        count(distinct case when status = 'FAILED' then payment_id end) as failed_transactions,
        sum(case when status = 'SUCCESS' then amount else 0 end) as collected_revenue,
        sum(amount) as attempted_revenue,
        avg(case when status = 'SUCCESS' then amount end) as avg_transaction_size
    from payments
    where payment_date is not null
    group by 1,2
),

-- Calculate totals per month for share percentages
monthly_totals as (
    select
        payment_month,
        sum(collected_revenue) as total_monthly_revenue,
        sum(successful_transactions) as total_monthly_transactions
    from monthly_stats
    group by 1
),

-- Final report with success rates and share metrics
final as (
    select
        ms.payment_month,
        ms.payment_method,
        -- Volume Metrics
        ms.total_transactions,
        ms.successful_transactions,
        ms.failed_transactions,
        round(100.0 * ms.successful_transactions / nullif(ms.total_transactions, 0), 2) as success_rate_pct,
        -- Financial Metrics
        round(ms.collected_revenue, 2) as collected_revenue,
        round(ms.avg_transaction_size, 2) as avg_transaction_size,
        -- Market Share Analysis
        round(100.0 * ms.collected_revenue / nullif(mt.total_monthly_revenue, 0), 2) as revenue_share_pct,
        round(100.0 * ms.successful_transactions / nullif(mt.total_monthly_transactions, 0), 2) as transaction_share_pct,
        -- Growth Tracking (MoM)
        lag(ms.collected_revenue) over (partition by ms.payment_method order by ms.payment_month) as prev_month_revenue,
        case
            when lag(ms.collected_revenue) over (partition by ms.payment_method order by ms.payment_month) > 0
            then round(100.0 * (ms.collected_revenue - lag(ms.collected_revenue) over (partition by ms.payment_method order by ms.payment_month))
                / lag(ms.collected_revenue) over (partition by ms.payment_method order by ms.payment_month), 2)
            else null
        end as revenue_growth_mom_pct
    from monthly_stats ms
    join monthly_totals mt on ms.payment_month = mt.payment_month
)

select * from final
order by payment_month desc, collected_revenue desc
