{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_TIER_HISTORY

with source as (
    select * from {{ source('customer', 'CUSTOMER_TIER_HISTORY') }}
),

renamed as (
    select
        trim(tier_history_id) as tier_history_id,
        trim(customer_id) as customer_id,
        trim(previous_tier_id) as previous_tier_id,
        trim(new_tier_id) as new_tier_id,
        trim(change_reason) as change_reason,
        effective_date,
        points_at_change,
        spend_at_change,
        trim(notes) as notes,
        created_at,
        trim(created_by) as created_by
    from source
)

select * from renamed
