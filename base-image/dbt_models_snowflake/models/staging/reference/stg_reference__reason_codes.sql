{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.REASON_CODES

with source as (
    select * from {{ source('reference', 'REASON_CODES') }}
),

renamed as (
    select
        trim(reason_code_id) as reason_code_id,
        trim(entity_type) as entity_type,
        trim(reason_code) as reason_code,
        trim(reason_name) as reason_name,
        trim(reason_description) as reason_description,
        requires_notes,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
