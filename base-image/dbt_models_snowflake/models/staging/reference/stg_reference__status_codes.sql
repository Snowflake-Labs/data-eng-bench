{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.STATUS_CODES

with source as (
    select * from {{ source('reference', 'STATUS_CODES') }}
),

renamed as (
    select
        trim(status_code_id) as status_code_id,
        trim(entity_type) as entity_type,
        trim(status_code) as status_code,
        trim(status_name) as status_name,
        trim(status_description) as status_description,
        display_order,
        is_terminal,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
