-- Session Hourly Distribution
-- Sessions by hour of day

with web_sessions as (
    select * from {{ ref('stg_digital__web_sessions') }}
)

select
    extract(hour from session_start) as session_hour,
    count(distinct session_id) as session_count,
    count(distinct visitor_id) as unique_visitors,
    avg(duration_seconds) as avg_duration,
    avg(page_views) as avg_page_views
from web_sessions
group by 1
order by 1
