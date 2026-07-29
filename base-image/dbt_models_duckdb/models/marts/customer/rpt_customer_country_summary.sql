-- Customer Country Summary
-- Customer counts by country

with customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
),

countries as (
    select * from {{ ref('stg_reference__countries') }}
)

select
    ca.country_code,
    cn.country_name,
    cn.continent,
    count(distinct ca.customer_id) as customer_count,
    count(distinct ca.state_province) as states_covered,
    count(distinct ca.city) as cities_covered
from customer_addresses ca
left join countries cn on ca.country_code = cn.country_code_2
group by 1, 2, 3
order by 4 desc
