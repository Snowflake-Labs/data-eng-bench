{{
    config(
        materialized='view',
        tags=['inventory', 'staging']
    )
}}

-- Staging model for INVENTORY.STORE_DEPARTMENTS

with source as (
    select * from {{ source('inventory', 'STORE_DEPARTMENTS') }}
),

renamed as (
    select
        trim(department_id) as department_id,
        trim(store_id) as store_id,
        trim(department_code) as department_code,
        trim(department_name) as department_name,
        trim(floor) as floor,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
