{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_NOTES

with source as (
    select * from {{ source('customer', 'CUSTOMER_NOTES') }}
),

renamed as (
    select
        trim(note_id) as note_id,
        trim(customer_id) as customer_id,
        trim(note_type) as note_type,
        trim(note_subject) as note_subject,
        trim(note_content) as note_content,
        is_pinned,
        is_internal_only,
        trim(related_entity_type) as related_entity_type,
        trim(related_entity_id) as related_entity_id,
        created_at,
        updated_at,
        trim(created_by) as created_by,
        trim(updated_by) as updated_by
    from source
)

select * from renamed
