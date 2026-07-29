-- Customer Address Freshness
-- Identifies customers with old address data

with customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    ca.customer_id,
    c.customer_number,
    c.email,
    max(ca.updated_at) as last_address_update,
    date_diff('day', cast(max(ca.updated_at) as date), current_date) as days_since_update,
    count(distinct ca.address_id) as address_count
from customer_addresses ca
left join customers c on ca.customer_id = c.customer_id
group by 1, 2, 3
