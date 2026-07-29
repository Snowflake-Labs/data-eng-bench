-- Customer Postal Code Analysis
-- Groups customers by postal code

with customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
)

select
    ca.postal_code,
    ca.city,
    ca.state_province,
    ca.country_code,
    count(distinct ca.customer_id) as customer_count,
    count(distinct ca.address_id) as address_count
from customer_addresses ca
left join customers c on ca.customer_id = c.customer_id
where ca.postal_code is not null
group by 1, 2, 3, 4
order by 5 desc
