-- Device Type Analysis
-- Analyzes traffic by device

with web_sessions as (
    select * from {{ ref('stg_digital__web_sessions') }}
)

select
    device_type,
    count(distinct session_id) as session_count,
    count(distinct visitor_id) as unique_visitors,
    avg(page_views) as avg_pages_per_session,
    avg(duration_seconds) as avg_duration,
    round(100.0 * sum(case when is_converted then 1 else 0 end) / nullif(count(distinct session_id), 0), 2) as conversion_rate
from web_sessions
group by 1
