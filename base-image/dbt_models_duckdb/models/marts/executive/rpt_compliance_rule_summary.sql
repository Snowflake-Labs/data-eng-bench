-- Compliance Rule Summary
-- Summarizes compliance rules

with compliance_rules as (
    select * from {{ ref('stg_audit__compliance_rules') }}
),

compliance_violations as (
    select * from {{ ref('stg_audit__compliance_violations') }}
)

select
    cr.rule_id,
    cr.rule_name,
    cr.rule_type,
    cr.description,
    cr.is_active,
    count(distinct cv.violation_id) as violation_count,
    max(cv.detected_at) as last_violation
from compliance_rules cr
left join compliance_violations cv on cr.rule_id = cv.rule_id
group by 1, 2, 3, 4, 5
