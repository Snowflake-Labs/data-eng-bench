-- Customer Address Missing Data
-- Identifies customers with incomplete addresses

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
    ca.address_id,
    case when ca.address_line_1 is null or ca.address_line_1 = '' then 1 else 0 end as missing_address_line,
    case when ca.city is null or ca.city = '' then 1 else 0 end as missing_city,
    case when ca.state_province is null or ca.state_province = '' then 1 else 0 end as missing_state,
    case when ca.postal_code is null or ca.postal_code = '' then 1 else 0 end as missing_postal,
    case when ca.country_code is null or ca.country_code = '' then 1 else 0 end as missing_country
from customer_addresses ca
left join customers c on ca.customer_id = c.customer_id
where
    ca.address_line_1 is null or ca.address_line_1 = ''
    or ca.city is null or ca.city = ''
    or ca.postal_code is null or ca.postal_code = ''
    or ca.country_code is null or ca.country_code = ''
