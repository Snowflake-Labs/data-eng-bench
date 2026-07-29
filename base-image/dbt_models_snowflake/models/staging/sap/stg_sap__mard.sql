{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.MARD
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.MARD
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per mard
 */

with source as (

    select * from {{ source('sap', 'MARD') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        inventory_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(variant_id) as variant_id,
        trim(location_type) as location_type,
        trim(warehouse_id) as warehouse_id,
        trim(store_id) as store_id,
        trim(location_id) as location_id,
        quantity_on_hand as quantity_on_hand,
        quantity_available as quantity_available,
        quantity_reserved as quantity_reserved,
        quantity_incoming as quantity_incoming,
        quantity_on_hold as quantity_on_hold,
        trim(unit_cost) as unit_cost,
        trim(inventory_status) as inventory_status,
        last_counted_at as last_counted_at,
        last_received_at as last_received_at,
        last_picked_at as last_picked_at,
        created_at as created_at,
        updated_at as updated_at,

        /*
         * Metadata Columns
         */
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash

    from source

)

select * from renamed
