{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'product', 'pricing'],
        unique_key=['price_id']
    )
}}

/*
    Staging model: stg_legacy__price_list
    Grain: Per price record (variant, price type, tier, channel)
    Unique Key: price_id
    Source: RAW_LEGACY.PRCLST
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__prclst') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(price_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        price_id,

        -- Relationships
        variant_id,
        substr(variant_id, 1, 15) as product_id,  -- Link to product
        substr(variant_id, 1, 10) as brand_id,    -- Link to brand
        customer_tier_id,
        channel_id,

        -- Price Attributes
        price_type,
        currency_code,
        {{ safe_cast('price_amount', 'decimal(18,2)') }} as price_amount,
        {{ safe_cast('compare_at_price', 'decimal(18,2)') }} as compare_at_price,
        {{ safe_cast('cost_price', 'decimal(18,2)') }} as cost_price,

        -- Quantity Tiers
        {{ safe_cast('min_qty', 'integer') }} as min_qty,
        {{ safe_cast('max_qty', 'integer') }} as max_qty,

        -- Validity Period
        {{ standardize_date('effective_from') }} as effective_from,
        {{ standardize_date('effective_to') }} as effective_to,

        -- Flags
        {{ safe_cast('is_active', 'boolean') }} as is_active,

        -- Timestamps
        {{ standardize_date('created_at') }} as created_at,
        {{ standardize_date('updated_at') }} as updated_at,
        created_by,

        -- Metadata
        _loaded_at,
        _source_system,
        _batch_id,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
