-- Inventory Count Variance
-- Analyzes count variances

with inventory_count_details as (
    select * from {{ ref('stg_inventory__inventory_count_details') }}
),

inventory_counts as (
    select * from {{ ref('stg_inventory__inventory_counts') }}
)

select
    ic.count_id,
    ic.count_type,
    ic.status,
    icd.variant_id,
    icd.system_quantity,
    icd.counted_quantity,
    icd.variance_quantity,
    case 
        when icd.variance_quantity > 0 then 'Overage'
        when icd.variance_quantity < 0 then 'Shortage'
        else 'Accurate'
    end as variance_type,
    abs(icd.variance_quantity) as abs_variance
from inventory_count_details icd
left join inventory_counts ic on icd.count_id = ic.count_id
where icd.variance_quantity != 0
