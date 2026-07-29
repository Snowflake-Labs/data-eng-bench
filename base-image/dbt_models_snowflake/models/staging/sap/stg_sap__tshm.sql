{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.TSHM
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.TSHM
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per tshm
 */

with source as (

    select * from {{ source('sap', 'TSHM') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        shipping_method_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(shipping_method_code) as shipping_method_code,
        trim(shipping_method_name) as shipping_method_name,
        trim(carrier_id) as carrier_id,
        estimated_days_min as estimated_days_min,
        estimated_days_max as estimated_days_max,
        is_express as is_express,
        is_active as is_active,
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
