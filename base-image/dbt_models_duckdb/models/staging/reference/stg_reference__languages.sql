{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.LANGUAGES

with source as (
    select * from {{ source('reference', 'LANGUAGES') }}
),

renamed as (
    select
        trim(language_code) as language_code,
        trim(language_name) as language_name,
        trim(native_name) as native_name,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
