with source as (
    select * from {{ source('raw_sfdc', 'account_tiers') }}
),

renamed as (
    select
        tier_id as tier_id,
        tier_code as tier_code,
        tier_name as tier_name,
        tier_level as tier_level,
        min_points_required as min_points_required,
        min_spend_required as min_spend_required,
        points_multiplier as points_multiplier,
        discount_percentage as discount_percentage,
        free_shipping as free_shipping,
        benefits_description as benefits_description,
        tier_color as tier_color,
        tier_icon as tier_icon,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
