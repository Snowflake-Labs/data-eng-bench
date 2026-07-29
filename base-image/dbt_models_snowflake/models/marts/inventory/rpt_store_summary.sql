-- Store Summary
-- Summarizes store information

with stores as (
    select * from {{ ref('stg_inventory__stores') }}
),

store_departments as (
    select
        store_id,
        count(distinct department_id) as department_count
    from {{ ref('stg_inventory__store_departments') }}
    group by 1
)

select
    s.store_id,
    s.store_number,
    s.store_name,
    s.store_type,
    s.city,
    s.supports_bopis,
    s.supports_ship_from_store,
    sd.department_count,
    s.latitude,
    s.longitude
from stores s
left join store_departments sd on s.store_id = sd.store_id
