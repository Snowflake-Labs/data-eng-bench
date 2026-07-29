{{
    config(
        materialized='view',
        tags=['staging', 'legacy', 'procurement', 'purchase_orders'],
        unique_key=['supplier_id', 'purchase_order_id']
    )
}}

/*
    Staging model: stg_legacy__purchase_orders
    Grain: Per supplier, per purchase order
    Unique Key: supplier_id, purchase_order_id
    Source: RAW_LEGACY.POHDR (Purchase Order Headers)
*/

with raw_data as (
    select *
    from {{ ref('raw_legacy__pohdr') }}
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(po_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        po_id as purchase_order_id,
        supplier_id,

        -- Relationships
        substr(supplier_id, 1, 5) as vendor_country_id,
        warehouse_id,

        -- PO Attributes
        po_number,
        status,
        currency_code,
        {{ safe_cast('total_amount', 'decimal(18,2)') }} as total_amount,

        -- Dates
        {{ standardize_date('expected_date') }} as expected_date,
        {{ standardize_date('ordered_at') }} as ordered_at,

        -- Audit
        created_by,
        {{ standardize_date('created_at') }} as created_at,
        {{ standardize_date('updated_at') }} as updated_at,

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
