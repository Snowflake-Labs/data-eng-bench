-- Web Event Analysis
-- Analyzes web events

with web_events as (
    select * from {{ ref('stg_digital__web_events') }}
)

select
    event_type,
    event_name,
    count(distinct event_id) as event_count,
    count(distinct session_id) as sessions_with_event,
    count(distinct product_id) as products_involved,
    min(event_timestamp) as first_event,
    max(event_timestamp) as last_event
from web_events
group by 1, 2
