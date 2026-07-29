-- Web Session Summary
-- Summarizes web sessions

with web_sessions as (
    select * from {{ ref('stg_digital__web_sessions') }}
)

select
    DATE_TRUNC(day, session_start) as session_date,
    device_type,
    browser,
    count(distinct session_id) as session_count,
    count(distinct visitor_id) as unique_visitors,
    count(distinct customer_id) as identified_customers,
    sum(page_views) as total_page_views,
    avg(duration_seconds) as avg_duration_seconds,
    sum(case when is_converted then 1 else 0 end) as converted_sessions,
    round(100.0 * sum(case when is_converted then 1 else 0 end) / nullif(count(distinct session_id), 0), 2) as conversion_rate
from web_sessions
group by 1, 2, 3
