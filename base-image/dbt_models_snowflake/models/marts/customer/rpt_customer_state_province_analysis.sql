-- Customer State Province Analysis
-- Customer distribution by state/province

with customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),

states_provinces as (
    select * from {{ ref('stg_reference__states_provinces') }}
)

select
    ca.state_province,
    ca.country_code,
    sp.state_name,
    count(distinct ca.customer_id) as customer_count,
    count(distinct ca.city) as cities_count,
    count(distinct ca.postal_code) as postal_codes_count
from customer_addresses ca
left join states_provinces sp on ca.state_province = sp.state_code
group by 1, 2, 3
order by 4 desc
