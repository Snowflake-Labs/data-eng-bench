{{
    config(
        materialized='view',
        tags=['audit', 'staging']
    )
}}

-- Staging model for AUDIT.DATA_MASKING_RULES

with source as (
    select * from {{ source('audit', 'DATA_MASKING_RULES') }}
),

renamed as (
    select
        trim(rule_id) as rule_id,
        trim(table_name) as table_name,
        trim(column_name) as column_name,
        trim(masking_type) as masking_type,
        is_active,
        created_at
    from source
)

select * from renamed
