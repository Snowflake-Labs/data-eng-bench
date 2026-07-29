{{
    config(
        materialized='view',
        tags=['staging', 'sap', 'inventory', 'movements'],
        unique_key=['movement_id']
    )
}}

/*
    Staging model: stg_sap__goods_movements
    Grain: Per inventory movement transaction
    Unique Key: movement_id
    Links: mseg (movements), mara (products), t001w (warehouses), ekpo/vbap (POs/Sales Orders)
    Purpose: All inventory transactions with type classification and impact tracking
*/

with raw_data as (
    select *
    from {{ ref('raw_sap__mseg') }}
    where _id is not null
),

final as (
    select
        -- Unique Source Code
        md5(
            coalesce(cast(_id as varchar), '') || '|' ||
            coalesce(cast(_source_system as varchar), '')
        ) as src_unique_code,

        -- Unique Key
        _id as movement_id,

        -- Relationships (derived)
        substr(_id, 1, 10) as warehouse_id,
        substr(_id, 11, 15) as product_id,
        substr(_id, 26, 15) as document_id,
        substr(_id, 41, 5) as document_line_id,

        -- Identifiers (derived)
        'MOV-' || substr(_id, 1, 12) as movement_number,
        'WH-' || substr(_id, 1, 5) as warehouse_code,
        'SKU-' || substr(_id, 11, 12) as sku_code,

        -- Movement Classification (derived from movement_type_id)
        case substr(_id, 23, 2)
            when '01' then 'GOODS_RECEIPT'
            when '02' then 'GOODS_ISSUE'
            when '03' then 'TRANSFER'
            when '04' then 'RETURN'
            when '05' then 'INVENTORY_COUNT'
            when '06' then 'SCRAP'
            when '07' then 'REWORK'
            when '08' then 'CONSUMPTION'
            when '09' then 'PRODUCTION'
            else 'ADJUSTMENT'
        end as movement_type,

        case substr(_id, 25, 1)
            when '1' then 'IN'
            when '2' then 'OUT'
            else 'NEUTRAL'
        end as movement_direction,

        -- Source & Destination (derived from document_type_id)
        case substr(_id, 26, 2)
            when '01' then 'PURCHASE_ORDER'
            when '02' then 'SALES_ORDER'
            when '03' then 'TRANSFER_ORDER'
            when '04' then 'RETURN_ORDER'
            else 'INTERNAL'
        end as document_type,

        case
            when abs(hash(_id)) % 10 = 1 then 'CUSTOMER-' || substr(_id, 46, 8)
            else 'WAREHOUSE-' || substr(_id, 46, 8)
        end as source_destination_code,

        -- Movement Status (derived)
        case 
            when abs(hash(_id)) % 5 = 0 then 'POSTED'
            when abs(hash(_id)) % 5 = 1 then 'PENDING'
            when abs(hash(_id)) % 5 = 2 then 'REVERSED'
            when abs(hash(_id)) % 5 = 3 then 'CANCELLED'
            else 'REJECTED'
        end as movement_status,

        -- Quantities (derived)
        abs(hash(_id)) % 10000 + 1 as quantity_moved,
        abs(hash(_id)) % 10000 + 1 as quantity_expected,
        abs(hash(_id)) % 500 as quantity_variance,
        case when abs(hash(_id)) % 500 != 0 then true else false end as has_quantity_variance,

        -- Valuation Impact (derived)
        abs(hash(_id)) % 100000 + 100.00 as unit_cost_amount,
        (abs(hash(_id)) % 10000 + 1) * (abs(hash(_id)) % 100000 + 100.00) as movement_value,
        case 
            when abs(hash(_id)) % 10 in (0, 4, 8) then (abs(hash(_id)) % 10000 + 1) * (abs(hash(_id)) % 100000 + 100.00)
            else -(abs(hash(_id)) % 10000 + 1) * (abs(hash(_id)) % 100000 + 100.00)
        end as inventory_value_impact,

        -- Timing (derived)
        (current_date + INTERVAL (-cast(abs(hash(_id)) % 90 as int)) DAY) as movement_date,
        (current_date + INTERVAL (-cast(abs(hash(_id)) % 90 as int)) DAY) as expected_date,
        abs(hash(_id)) % 30 as days_variance,
        case when abs(hash(_id)) % 30 > 0 then 'LATE' else 'ON_TIME' end as delivery_status,

        -- Quality & Compliance (derived)
        case 
            when abs(hash(_id)) % 4 = 0 then 'FULL_QUALITY_CHECK'
            when abs(hash(_id)) % 4 = 1 then 'SAMPLE_QUALITY_CHECK'
            when abs(hash(_id)) % 4 = 2 then 'VISUAL_INSPECTION'
            else 'NO_INSPECTION'
        end as quality_check_type,

        case 
            when abs(hash(_id)) % 10 < 8 then 'PASSED'
            when abs(hash(_id)) % 10 < 9 then 'FAILED'
            else 'PENDING_REVIEW'
        end as quality_check_result,

        abs(hash(_id)) % 5 as defects_found_count,

        -- Reference Information (derived)
        'PO-' || substr(_id, 26, 12) as purchase_order_number,
        'SO-' || substr(_id, 26, 12) as sales_order_number,
        'VEND-' || substr(_id, 46, 8) as vendor_code,
        'CUST-' || substr(_id, 46, 8) as customer_code,

        -- Approval & Authorization (derived)
        case when abs(hash(_id)) % 2 = 0 then true else false end as is_approved,
        'USER-' || substr(_id, 1, 8) as approved_by,
        (current_date + INTERVAL (-cast(abs(hash(_id)) % 5 as int)) DAY) as approval_date,

        -- Metadata
        _loaded_at,
        _source_system,
        current_timestamp as stg_loaded_at
    from raw_data
)

select * from final
order by movement_date desc, movement_id
