{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.CARRIERS

with source as (
    select * from {{ source('reference', 'CARRIERS') }}
),

renamed as (
    select
        trim(carrier_id) as carrier_id,
        trim(carrier_code) as carrier_code,
        trim(carrier_name) as carrier_name,
        trim(carrier_type) as carrier_type,
        trim(tracking_url_template) as tracking_url_template,
        trim(api_endpoint) as api_endpoint,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
