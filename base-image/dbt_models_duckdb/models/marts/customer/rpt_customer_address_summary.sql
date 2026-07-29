-- Customer Address Summary
-- Summarizes address information per customer including billing/shipping defaults

with customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    ca.customer_id,
    c.customer_number,
    c.first_name,
    c.last_name,
    count(distinct ca.address_id) as total_addresses,
    count(distinct case when ca.is_default_billing then ca.address_id end) as billing_addresses,
    count(distinct case when ca.is_default_shipping then ca.address_id end) as shipping_addresses,
    count(distinct ca.country_code) as countries_count,
    count(distinct ca.state_province) as states_count,
    count(distinct ca.city) as cities_count,
    max(ca.created_at) as latest_address_added_at,
    min(ca.created_at) as first_address_added_at
from customer_addresses ca
left join customers c on ca.customer_id = c.customer_id
group by 1, 2, 3, 4
