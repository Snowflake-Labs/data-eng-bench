-- Customer Segment Empty Check
-- Identifies segments with no members

with customer_segments as (
    select * from {{ ref('stg_customer__customer_segments') }}
),

customer_segment_members as (
    select * from {{ ref('stg_customer__customer_segment_members') }}
)

select
    cs.segment_id,
    cs.segment_code,
    cs.segment_name,
    cs.segment_type,
    cs.member_count as reported_count,
    count(distinct csm.customer_id) as actual_count,
    cs.created_at,
    case when count(distinct csm.customer_id) = 0 then 'Empty' else 'Has Members' end as segment_status
from customer_segments cs
left join customer_segment_members csm on cs.segment_id = csm.segment_id
group by 1, 2, 3, 4, 5, 7
