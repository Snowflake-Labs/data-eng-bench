-- Supplier Address Summary
-- Summarizes supplier addresses

with supplier_addresses as (
    select * from {{ ref('stg_procurement__supplier_addresses') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    s.supplier_name,
    sa.address_type,
    sa.city,
    sa.country_code,
    count(distinct sa.address_id) as address_count
from supplier_addresses sa
left join suppliers s on sa.supplier_id = s.supplier_id
group by 1, 2, 3, 4
