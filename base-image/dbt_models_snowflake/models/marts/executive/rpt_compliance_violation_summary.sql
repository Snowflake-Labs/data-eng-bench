-- Compliance Violation Summary
-- Summarizes compliance violations

with compliance_violations as (
    select * from {{ ref('stg_audit__compliance_violations') }}
),

compliance_rules as (
    select * from {{ ref('stg_audit__compliance_rules') }}
)

select
    cr.rule_name,
    cr.rule_type,
    cv.entity_type,
    count(distinct cv.violation_id) as violation_count,
    count(distinct cv.entity_id) as entities_affected,
    min(cv.detected_at) as first_detected,
    max(cv.detected_at) as last_detected
from compliance_violations cv
left join compliance_rules cr on cv.rule_id = cr.rule_id
group by 1, 2, 3
