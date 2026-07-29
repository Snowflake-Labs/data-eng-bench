-- Campaign Status Summary
-- Campaigns by status

with marketing_campaigns as (
    select * from {{ ref('stg_marketing__marketing_campaigns') }}
)

select
    status,
    campaign_type,
    count(distinct campaign_id) as campaign_count,
    sum(budget) as total_budget,
    min(start_date) as earliest_start,
    max(end_date) as latest_end
from marketing_campaigns
group by 1, 2
