-- Contract Item Summary
-- Summarizes contract items

with purchase_contract_items as (
    select * from {{ ref('stg_procurement__purchase_contract_items') }}
),

purchase_contracts as (
    select * from {{ ref('stg_procurement__purchase_contracts') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    pc.contract_id,
    pc.contract_type,
    count(distinct pci.variant_id) as variants_in_contract,
    sum(pci.min_quantity) as total_min_quantity,
    sum(pci.max_quantity) as total_max_quantity,
    avg(pci.unit_price) as avg_unit_price
from purchase_contract_items pci
left join purchase_contracts pc on pci.contract_id = pc.contract_id
left join product_variants pv on pci.variant_id = pv.variant_id
group by 1, 2
