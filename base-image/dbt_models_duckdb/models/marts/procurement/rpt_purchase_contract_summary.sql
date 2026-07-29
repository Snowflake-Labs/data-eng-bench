-- Purchase Contract Summary
-- Summarizes purchase contracts

with purchase_contracts as (
    select * from {{ ref('stg_procurement__purchase_contracts') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    pc.contract_type,
    s.supplier_name,
    count(distinct pc.contract_id) as contract_count,
    sum(pc.total_value) as total_contract_value,
    min(pc.start_date) as earliest_start,
    max(pc.end_date) as latest_end,
    sum(case when pc.end_date < current_date then 1 else 0 end) as expired_contracts
from purchase_contracts pc
left join suppliers s on pc.supplier_id = s.supplier_id
group by 1, 2
