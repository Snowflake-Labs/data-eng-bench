-- Customer Default Address Summary
-- Shows customers with/without default addresses

with customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    c.customer_id,
    c.customer_number,
    c.email,
    c.customer_type,
    max(case when ca.is_default_billing then 1 else 0 end) as has_default_billing,
    max(case when ca.is_default_shipping then 1 else 0 end) as has_default_shipping,
    count(distinct ca.address_id) as total_addresses
from customers c
left join customer_addresses ca on c.customer_id = ca.customer_id
group by 1, 2, 3, 4
