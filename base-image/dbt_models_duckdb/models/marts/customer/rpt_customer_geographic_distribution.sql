-- Customer Geographic Distribution
-- Shows customer distribution by geography

with customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    ca.country_code,
    ca.state_province,
    ca.city,
    count(distinct ca.customer_id) as customer_count,
    count(distinct case when ca.is_default_shipping then ca.customer_id end) as customers_shipping_here,
    count(distinct case when ca.is_default_billing then ca.customer_id end) as customers_billing_here
from customer_addresses ca
left join customers c on ca.customer_id = c.customer_id
group by 1, 2, 3
