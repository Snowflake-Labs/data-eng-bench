with spend as (
    select 
        channel_type, 
        date_trunc('month', metric_date) as month,
        sum(spend) as cost
    from {{ ref('stg_marketing__campaign_performance') }} cp
    join {{ ref('stg_marketing__campaign_channels') }} cc on cp.campaign_id = cc.campaign_id
    group by 1,2
),
revenue as (
    select 
        c.channel_name,
        date_trunc('month', o.ordered_at) as month,
        sum(o.grand_total) as sales
    from {{ ref('stg_orders__orders') }} o
    join {{ ref('stg_orders__channels') }} c on o.channel_id = c.channel_id
    group by 1,2
)

select 
    coalesce(s.channel_type, r.channel_name) as channel,
    coalesce(s.month, r.month) as month,
    s.cost,
    r.sales,
    case when s.cost > 0 then r.sales / s.cost else 0 end as roas
from spend s
full outer join revenue r on s.channel_type = r.channel_name and s.month = r.month