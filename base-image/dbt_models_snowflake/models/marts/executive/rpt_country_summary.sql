-- Reference Country Summary
-- Summarizes country reference data

with countries as (
    select * from {{ ref('stg_reference__countries') }}
),

customers as (
    select * from {{ ref('stg_customer__customers') }}
),

customer_addresses as (
    select * from {{ ref('stg_customer__customer_addresses') }}
)

select
    c.country_name,
    c.currency_code,
    count(distinct ca.customer_id) as customer_count
from countries c
left join customer_addresses ca on c.country_code_2 = ca.country_code
group by 1, 2
