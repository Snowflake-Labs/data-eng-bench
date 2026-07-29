-- Supplier Detail Dimension
-- Comprehensive supplier dimension

with suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
),

supplier_addresses as (
    select * from {{ ref('stg_procurement__supplier_addresses') }}
),

supplier_contacts as (
    select * from {{ ref('stg_procurement__supplier_contacts') }}
)

select
    s.supplier_id,
    s.supplier_name,
    s.supplier_type,
    s.status as supplier_status,
    s.payment_terms,
    sa.city,
    sa.country_code,
    sc.contact_name as primary_contact,
    sc.email as primary_email,
    sc.phone as primary_phone
from suppliers s
left join supplier_addresses sa on s.supplier_id = sa.supplier_id and sa.is_primary = true
left join supplier_contacts sc on s.supplier_id = sc.supplier_id and sc.is_primary = true