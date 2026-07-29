-- Supplier Certification Status
-- Tracks supplier certifications

with supplier_certifications as (
    select * from {{ ref('stg_procurement__supplier_certifications') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    sc.certification_type,
    count(distinct sc.supplier_id) as suppliers_certified,
    sum(case when sc.expiry_date > current_date then 1 else 0 end) as active_certifications,
    sum(case when sc.expiry_date <= current_date then 1 else 0 end) as expired_certifications,
    min(sc.expiry_date) as nearest_expiry
from supplier_certifications sc
left join suppliers s on sc.supplier_id = s.supplier_id
group by 1
