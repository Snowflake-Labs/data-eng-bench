with customer_spend as (
    select 
        c.customer_id,
        sum(o.grand_total) as total_spend
    from {{ ref('stg_customer__customers') }} c
    join {{ ref('stg_orders__orders') }} o on c.customer_id = o.customer_id
    group by 1
),
marketing_spend as (
    select 
        sum(spend) as total_marketing_spend,
        sum(conversions) as total_conversions
    from {{ ref('stg_marketing__campaign_performance') }}
),
customer_cac as (
    select 
        cs.customer_id,
        cs.total_spend,
        (ms.total_marketing_spend / nullif(ms.total_conversions, 0)) as estimated_cac
    from customer_spend cs
    cross join marketing_spend ms
)

select 
    customer_id,
    total_spend,
    estimated_cac,
    case when total_spend > 0 then estimated_cac / (total_spend / 12) else null end as months_to_payback
from customer_cac