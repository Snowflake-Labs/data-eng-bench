-- User Access Log Summary
-- Summarizes user access

with user_access_logs as (
    select * from {{ ref('stg_audit__user_access_logs') }}
)

select
    access_type,
    date_trunc('day', access_timestamp) as access_date,
    count(distinct access_id) as access_count,
    count(distinct user_id) as unique_users,
    count(distinct ip_address) as unique_ips
from user_access_logs
group by 1, 2
order by 2, 1
