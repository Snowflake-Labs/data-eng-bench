-- Campaign Channel Distribution
-- Campaigns by channel

with campaign_channels as (
    select * from {{ ref('stg_marketing__campaign_channels') }}
),

marketing_campaigns as (
    select * from {{ ref('stg_marketing__marketing_campaigns') }}
)

select
    cc.channel_type,
    count(distinct cc.campaign_id) as campaign_count,
    sum(cc.allocated_budget) as total_allocated_budget,
    avg(cc.allocated_budget) as avg_budget_per_campaign
from campaign_channels cc
left join marketing_campaigns mc on cc.campaign_id = mc.campaign_id
group by 1
