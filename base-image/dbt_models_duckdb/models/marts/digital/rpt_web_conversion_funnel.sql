with session_stats as (
    select 
        date_trunc('day', session_start) as date,
        count(session_id) as total_sessions,
        sum(case when is_converted = true then 1 else 0 end) as sessions_with_order
    from {{ ref('stg_digital__web_sessions') }}
    group by 1
)

select 
    date,
    total_sessions,
    sessions_with_order,
    (sessions_with_order * 1.0 / nullif(total_sessions,0)) as overall_conversion_rate
from session_stats