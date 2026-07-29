with src_stg_digital__web_sessions as (
    select * from {{ ref('stg_digital__web_sessions') }}
),

-- Aggregating from raw_ga or digital schemas
sessions as (
    select * from src_stg_digital__web_sessions
)

select
    DATE_TRUNC(day, session_start) as summary_date,
    device_type,
    count(distinct session_id) as total_sessions,
    avg(duration_seconds) as avg_duration_sec,
    sum(case when page_views > 1 then 1 else 0 end) as engaged_sessions
from sessions
group by 1,2
