-- Customer Multi-Segment Membership
-- Identifies customers belonging to multiple segments

with customer_segment_members as (
    select * from {{ ref('stg_customer__customer_segment_members') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

customer_segments as (
    select * from {{ ref('stg_customer__customer_segments') }}
)

select
    csm.customer_id,
    c.customer_number,
    c.first_name,
    c.last_name,
    c.customer_type,
    count(distinct csm.segment_id) as segment_count,
    LISTAGG(distinct cs.segment_name, ', ') within group (order by cs.segment_name) as segment_names,
    min(csm.added_date) as first_segment_added,
    max(csm.added_date) as last_segment_added
from customer_segment_members csm
left join customers c on csm.customer_id = c.customer_id
left join customer_segments cs on csm.segment_id = cs.segment_id
group by 1, 2, 3, 4, 5
having count(distinct csm.segment_id) > 1
