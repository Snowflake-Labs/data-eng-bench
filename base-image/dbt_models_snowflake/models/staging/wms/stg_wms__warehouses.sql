{{
    config(
        materialized='view',
        tags=['wms', 'staging']
    )
}}

/*
 * Staging model for RAW_WMS.WAREHOUSES
 *
 * Entity Type: table
 * Source: WMS - RAW_WMS.WAREHOUSES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per warehouses
 */

with source as (

    select * from {{ source('wms', 'WAREHOUSES') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        warehouse_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(warehouse_code) as warehouse_code,
        trim(warehouse_name) as warehouse_name,
        trim(warehouse_type) as warehouse_type,
        trim(address_line_1) as address_line_1,
        trim(city) as city,
        trim(state_province) as state_province,
        trim(postal_code) as postal_code,
        trim(country_code) as country_code,
        latitude as latitude,
        longitude as longitude,
        trim(timezone) as timezone,
        trim(phone) as phone,
        trim(email) as email,
        trim(manager_name) as manager_name,
        square_footage as square_footage,
        max_capacity_units as max_capacity_units,
        opened_date as opened_date,
        priority as priority,
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
