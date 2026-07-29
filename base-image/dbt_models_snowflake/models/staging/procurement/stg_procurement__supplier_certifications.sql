{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.SUPPLIER_CERTIFICATIONS

with source as (
    select * from {{ source('procurement', 'SUPPLIER_CERTIFICATIONS') }}
),

renamed as (
    select
        trim(certification_id) as certification_id,
        trim(supplier_id) as supplier_id,
        trim(certification_type) as certification_type,
        trim(certification_name) as certification_name,
        trim(issued_by) as issued_by,
        issue_date,
        expiry_date,
        trim(status) as status,
        created_at
    from source
)

select * from renamed
