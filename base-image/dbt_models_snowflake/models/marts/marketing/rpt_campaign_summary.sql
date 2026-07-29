-- Marketing Campaign Summary
-- Summarizes marketing campaigns

with marketing_campaigns as (
    select * from {{ ref('stg_marketing__marketing_campaigns') }}
),

campaign_performance as (
    select * from {{ ref('stg_marketing__campaign_performance') }}
)

select
    mc.campaign_id,
    mc.campaign_code,
    mc.campaign_name,
    mc.campaign_type,
    mc.start_date,
    mc.end_date,
    mc.budget,
    mc.status,
    sum(cp.impressions) as total_impressions,
    sum(cp.clicks) as total_clicks,
    sum(cp.conversions) as total_conversions,
    sum(cp.spend) as total_spend,
    sum(cp.revenue) as total_revenue
from marketing_campaigns mc
left join campaign_performance cp on mc.campaign_id = cp.campaign_id
group by 1, 2, 3, 4, 5, 6, 7, 8
