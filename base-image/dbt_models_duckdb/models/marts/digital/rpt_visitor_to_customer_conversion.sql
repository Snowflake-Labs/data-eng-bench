-- Visitor to Customer Conversion
-- Tracks visitor to customer conversion

with web_sessions as (
    select * from {{ ref('stg_digital__web_sessions') }}
)

select
    date_trunc('week', session_start) as session_week,
    count(distinct visitor_id) as total_visitors,
    count(distinct customer_id) as identified_customers,
    count(distinct case when is_converted then visitor_id end) as converting_visitors,
    round(100.0 * count(distinct customer_id) / nullif(count(distinct visitor_id), 0), 2) as identification_rate,
    round(100.0 * count(distinct case when is_converted then visitor_id end) / nullif(count(distinct visitor_id), 0), 2) as conversion_rate
from web_sessions
group by 1
order by 1
