-- Promotion Rule Summary
-- Summarizes promotion rules

with promotion_rules as (
    select * from {{ ref('stg_marketing__promotion_rules') }}
),

promotions as (
    select * from {{ ref('stg_marketing__promotions') }}
)

select
    pr.rule_type,
    pr.rule_operator,
    count(distinct pr.rule_id) as rule_count,
    count(distinct pr.promotion_id) as promotions_with_rule
from promotion_rules pr
left join promotions p on pr.promotion_id = p.promotion_id
group by 1, 2
