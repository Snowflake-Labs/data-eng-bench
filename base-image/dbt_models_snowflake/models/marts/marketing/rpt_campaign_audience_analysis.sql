-- Campaign Audience Analysis
-- Analyzes campaign audiences

with campaign_audiences as (
    select * from {{ ref('stg_marketing__campaign_audiences') }}
),

marketing_campaigns as (
    select * from {{ ref('stg_marketing__marketing_campaigns') }}
),

customer_segments as (
    select * from {{ ref('stg_customer__customer_segments') }}
)

select
    mc.campaign_name,
    mc.campaign_type,
    cs.segment_name,
    cs.segment_type,
    ca.audience_size,
    mc.budget,
    mc.budget / nullif(ca.audience_size, 0) as budget_per_audience_member
from campaign_audiences ca
left join marketing_campaigns mc on ca.campaign_id = mc.campaign_id
left join customer_segments cs on ca.segment_id = cs.segment_id
