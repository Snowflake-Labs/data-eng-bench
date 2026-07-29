with page_views as (
    select * from {{ ref('stg_digital__web_page_views') }}
)

select
    session_id,
    LISTAGG(page_url, ' > ') WITHIN GROUP (ORDER BY view_timestamp) as journey_path,
    count(*) as path_length,
    TIMESTAMPDIFF(second, min(view_timestamp), max(view_timestamp)) as session_duration
from page_views
group by 1
having count(*) > 1
