-- Customer Address Type Distribution
-- Shows distribution of address types per customer

with customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
)

select
    address_type,
    country_code,
    count(distinct customer_id) as unique_customers,
    count(distinct address_id) as total_addresses,
    sum(case when is_default_billing then 1 else 0 end) as default_billing_count,
    sum(case when is_default_shipping then 1 else 0 end) as default_shipping_count
from customer_addresses
group by 1, 2
