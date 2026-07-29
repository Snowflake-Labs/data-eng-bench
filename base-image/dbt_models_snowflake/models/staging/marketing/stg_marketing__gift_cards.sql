{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.GIFT_CARDS

with source as (
    select * from {{ source('marketing', 'GIFT_CARDS') }}
),

renamed as (
    select
        trim(gift_card_id) as gift_card_id,
        trim(card_number) as card_number,
        initial_value,
        current_balance,
        trim(currency_code) as currency_code,
        trim(status) as status,
        trim(purchased_by) as purchased_by,
        activated_at,
        expires_at,
        created_at
    from source
)

select * from renamed
