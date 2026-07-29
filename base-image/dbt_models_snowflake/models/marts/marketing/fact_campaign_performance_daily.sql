/*
================================================================================
Campaign Daily Performance Fact

@author: Marketing Analytics Team (Amy Chen)
@created: 2023-09-10
@modified: 2024-11-05 - Added conversion rate calculation

Daily aggregation of campaign metrics from all marketing channels.
Used by marketing dashboards and budget allocation models.

Performance: Full refresh 4 min, ~2M rows
Schedule: Daily at 5 AM UTC (after marketing data lands at 3 AM)

KNOWN ISSUES:
- Facebook data delayed 24hrs, so yesterday's metrics incomplete until day+2
- Google Ads attribution window = 30d, causes late conversions
- TikTok integration broken since 2024-10-15 (DATA-1892)

TODO: Add cost-per-acquisition calculation
TODO: Add ROAS (return on ad spend) metric
TODO: Handle attribution window properly for accurate conversion counts
FIXME: conversion_rate_pct is misleading - it's click-to-conversion not impression
HACK: Using nullif to avoid div-by-zero but masks data quality issues
================================================================================
*/

with campaign_performance as (
    select * from {{ ref('stg_marketing__campaign_performance') }}
    -- FIXME: Filter out test campaigns that marketing forgot to exclude
),

marketing_campaigns as (
    select * from {{ ref('stg_marketing__marketing_campaigns') }}
)

select
    cp.metric_date,
    mc.campaign_name,
    mc.campaign_type,
    cp.impressions,
    cp.clicks,
    cp.conversions,
    cp.spend,
    cp.revenue,
    round(100.0 * cp.clicks / nullif(cp.impressions, 0), 2) as ctr_pct,
    round(100.0 * cp.conversions / nullif(cp.clicks, 0), 2) as conversion_rate_pct
from campaign_performance cp
left join marketing_campaigns mc on cp.campaign_id = mc.campaign_id
order by 1, 2
