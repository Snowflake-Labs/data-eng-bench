-- Supplier Contact Directory
-- Directory of supplier contacts

with supplier_contacts as (
    select * from {{ ref('stg_procurement__supplier_contacts') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    s.supplier_name,
    s.supplier_type,
    sc.contact_name,
    sc.email,
    sc.phone,
    sc.is_primary,
    s.status as supplier_status
from supplier_contacts sc
left join suppliers s on sc.supplier_id = s.supplier_id
