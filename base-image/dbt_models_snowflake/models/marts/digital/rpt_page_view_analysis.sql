-- Page View Analysis
-- Analyzes page views

with web_page_views as (
    select * from {{ ref('stg_digital__web_page_views') }}
)

select
    page_type,
    count(distinct page_view_id) as view_count,
    count(distinct session_id) as unique_sessions,
    avg(time_on_page_seconds) as avg_time_on_page,
    avg(scroll_depth_percent) as avg_scroll_depth,
    count(distinct page_url) as unique_pages
from web_page_views
group by 1
