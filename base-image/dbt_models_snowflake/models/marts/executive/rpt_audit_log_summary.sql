-- Audit Log Summary
-- Summarizes audit logs

with audit_logs as (
    select * from {{ ref('stg_audit__audit_logs') }}
)

select
    event_type,
    table_name as entity_type,
    DATE_TRUNC(day, event_timestamp) as log_date,
    count(distinct audit_id) as log_count,
    count(distinct user_id) as unique_users,
    count(distinct record_id) as unique_entities
from audit_logs
group by 1, 2, 3
order by 3, 1
