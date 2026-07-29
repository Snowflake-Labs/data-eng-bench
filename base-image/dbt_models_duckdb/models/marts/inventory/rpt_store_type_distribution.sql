-- Store Type Distribution
-- Distribution by store type

with stores as (
    select * from {{ ref('stg_inventory__stores') }}
)

select
    store_type,
    count(distinct store_id) as store_count,
    sum(case when supports_bopis then 1 else 0 end) as bopis_enabled,
    sum(case when supports_ship_from_store then 1 else 0 end) as ship_from_store_enabled,
    count(distinct city) as cities_covered
from stores
group by 1
