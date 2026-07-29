with audiences as (
    select campaign_id, sum(audience_size) as sent_count 
    from {{ ref('stg_marketing__campaign_audiences') }}
    group by 1
),
performance as (
    select campaign_id, sum(clicks) as click_count, sum(conversions) as conversion_count
    from {{ ref('stg_marketing__campaign_performance') }}
    group by 1
)

select 
    a.campaign_id,
    a.sent_count,
    coalesce(p.click_count, 0) as clicks,
    coalesce(p.conversion_count, 0) as conversions,
    (coalesce(p.click_count, 0) * 100.0 / nullif(a.sent_count, 0)) as click_rate
from audiences a
left join performance p on a.campaign_id = p.campaign_id