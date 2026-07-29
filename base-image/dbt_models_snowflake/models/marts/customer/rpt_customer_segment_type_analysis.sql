-- Customer Segment Type Analysis
-- Breaks down segments by type

with customer_segments as (
    select * from {{ ref('stg_customer__customer_segments') }}
),

customer_segment_members as (
    select * from {{ ref('stg_customer__customer_segment_members') }}
)

select
    cs.segment_type,
    count(distinct cs.segment_id) as segment_count,
    sum(cs.member_count) as total_reported_members,
    count(distinct csm.customer_id) as total_actual_members,
    avg(cs.member_count) as avg_segment_size
from customer_segments cs
left join customer_segment_members csm on cs.segment_id = csm.segment_id
group by 1
