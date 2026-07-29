-- UTM Source Analysis
-- Analyzes traffic by UTM source

with web_sessions as (
    select * from {{ ref('stg_digital__web_sessions') }}
)

select
    utm_source,
    utm_medium,
    utm_campaign,
    count(distinct session_id) as session_count,
    count(distinct visitor_id) as unique_visitors,
    sum(page_views) as total_page_views,
    avg(duration_seconds) as avg_duration,
    sum(case when is_converted then 1 else 0 end) as conversions,
    round(100.0 * sum(case when is_converted then 1 else 0 end) / nullif(count(distinct session_id), 0), 2) as conversion_rate
from web_sessions
where utm_source is not null
group by 1, 2, 3
