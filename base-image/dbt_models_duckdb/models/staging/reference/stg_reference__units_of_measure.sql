{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.UNITS_OF_MEASURE

with source as (
    select * from {{ source('reference', 'UNITS_OF_MEASURE') }}
),

renamed as (
    select
        trim(uom_code) as uom_code,
        trim(uom_name) as uom_name,
        trim(uom_type) as uom_type,
        trim(base_uom_code) as base_uom_code,
        conversion_factor,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
