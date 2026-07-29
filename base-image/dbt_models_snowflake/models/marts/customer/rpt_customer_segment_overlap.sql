-- Customer Segment Overlap
-- Identifies overlapping segments

with customer_segment_members as (
    select * from {{ ref('stg_customer__customer_segment_members') }}
),

customer_segments as (
    select * from {{ ref('stg_customer__customer_segments') }}
)

select
    cs1.segment_name as segment_1,
    cs2.segment_name as segment_2,
    count(distinct csm1.customer_id) as overlapping_customers
from customer_segment_members csm1
inner join customer_segment_members csm2
    on csm1.customer_id = csm2.customer_id
    and csm1.segment_id < csm2.segment_id
left join customer_segments cs1 on csm1.segment_id = cs1.segment_id
left join customer_segments cs2 on csm2.segment_id = cs2.segment_id
group by 1, 2
order by 3 desc
