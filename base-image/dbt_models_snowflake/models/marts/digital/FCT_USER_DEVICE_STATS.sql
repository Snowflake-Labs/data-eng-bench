with sessions as (
    select
        session_id,
        visitor_id,
        device_type,
        -- derive duration from start/end when the raw duration column is missing
        coalesce(duration_seconds, cast(TIMESTAMPDIFF(second, session_start, session_end) as integer)) as session_duration_seconds,
        page_views,
        is_converted,
        session_start
    from {{ ref('stg_digital__web_sessions') }}
),

visitor_device_metrics as (
    select
        visitor_id,
        device_type,
        count(session_id) as session_count,
        sum(session_duration_seconds) as total_time_spent,
        sum(page_views) as total_page_views,
        sum(case when is_converted = true then 1 else 0 end) as conversions,
        max(session_start) as last_session_start
    from sessions
    where visitor_id is not null
    group by visitor_id, device_type
),

visitor_totals as (
    select
        visitor_id,
        sum(session_count) as visitor_session_count,
        sum(total_time_spent) as visitor_time_spent,
        sum(total_page_views) as visitor_page_views,
        sum(conversions) as visitor_conversions
    from visitor_device_metrics
    group by visitor_id
)

-- Combine device aggregates with visitor totals to surface share + conversion context
select
    vdm.visitor_id,
    vdm.device_type,
    vdm.session_count,
    vdm.total_time_spent,
    vdm.total_page_views,
    vdm.conversions,
    vdm.last_session_start,
    round(vdm.total_time_spent::float / nullif(vdm.session_count, 0), 2) as avg_duration_seconds,
    round(vdm.total_page_views::float / nullif(vdm.session_count, 0), 2) as avg_page_views_per_session,
    round(vdm.conversions::float / nullif(vdm.session_count, 0), 4) as device_conversion_rate,
    round(vdm.session_count::float / nullif(vt.visitor_session_count, 0), 4) as visitor_session_share,
    rank() over (partition by vdm.visitor_id order by vdm.session_count desc) as device_rank,
    vt.visitor_session_count,
    vt.visitor_time_spent,
    vt.visitor_page_views,
    vt.visitor_conversions,
    round(vt.visitor_conversions::float / nullif(vt.visitor_session_count, 0), 4) as visitor_conversion_rate
from visitor_device_metrics vdm
join visitor_totals vt using (visitor_id)
