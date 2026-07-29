with orders as (
    select * from {{ ref('stg_orders__orders') }}
),
campaigns as (
    select * from {{ ref('stg_marketing__marketing_campaigns') }}
),
campaign_performance as (
    select * from {{ ref('stg_marketing__campaign_performance') }}
)

select 
    o.order_id,
    o.ordered_at,
    c.campaign_name,
    c.campaign_type,
    o.grand_total,
    cp.conversions as total_touches,
    o.grand_total / nullif(cp.conversions, 0) as attributed_revenue
from orders o
cross join campaigns c
left join campaign_performance cp on c.campaign_id = cp.campaign_id