-- Fact Customer Segment Membership
-- Detailed segment membership fact table

with customer_segment_members as (
    select * from {{ ref('stg_customer__customer_segment_members') }}
),

customer_segments as (
    select * from {{ ref('stg_customer__customer_segments') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    csm.customer_id,
    c.customer_number,
    c.customer_type,
    csm.segment_id,
    cs.segment_code,
    cs.segment_name,
    cs.segment_type,
    DATE_TRUNC('month', csm.added_date) as added_month,
    DATE_TRUNC(year, csm.added_date) as added_year
from customer_segment_members csm
left join customer_segments cs on csm.segment_id = cs.segment_id
left join customers c on csm.customer_id = c.customer_id
