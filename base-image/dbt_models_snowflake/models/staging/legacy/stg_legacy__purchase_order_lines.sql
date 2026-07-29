{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'procurement', 'purchase_order_lines'],
        unique_key=['po_line_id']
    )
}}

/*
    Staging model: stg_legacy__purchase_order_lines
    Grain: Per purchase order line
    Unique Key: po_line_id
    Source: RAW_LEGACY.PODTL (Purchase Order Details)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__podtl') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(po_line_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        po_line_id,

        -- Relationships
        po_id as purchase_order_id,
        variant_id,
        sku,

        -- Line Attributes
        {{ safe_cast('line_number', 'integer') }} as line_number,
        quantity_ordered,
        quantity_received,
        {{ safe_cast('unit_price', 'decimal(18,2)') }} as unit_price,
        {{ safe_cast('line_total', 'decimal(18,2)') }} as line_total,

        -- Timestamps
        {{ standardize_date('created_at') }} as created_at,

        -- Metadata
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
