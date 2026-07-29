{{
    config(
        materialized='view',
        tags=['audit', 'staging']
    )
}}

-- Staging model for AUDIT.DATA_CHANGE_HISTORY

with source as (
    select * from {{ source('audit', 'DATA_CHANGE_HISTORY') }}
),

renamed as (
    select
        trim(change_id) as change_id,
        trim(table_name) as table_name,
        trim(record_id) as record_id,
        trim(column_name) as column_name,
        trim(old_value) as old_value,
        trim(new_value) as new_value,
        trim(change_type) as change_type,
        trim(changed_by) as changed_by,
        changed_at
    from source
)

select * from renamed
