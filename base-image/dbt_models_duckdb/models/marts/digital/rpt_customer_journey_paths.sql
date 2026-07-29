with page_views as (
    select * from {{ ref('stg_digital__web_page_views') }}
)

select 
    session_id,
    string_agg(page_url, ' > ' order by view_timestamp) as journey_path,
    count(*) as path_length,
    max(view_timestamp) - min(view_timestamp) as session_duration
from page_views
group by 1
having count(*) > 1