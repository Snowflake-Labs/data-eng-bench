{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.CTRYCOD
 *
 * Entity Type: lookup
 * Source: LEGACY - RAW_LEGACY.CTRYCOD
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per ctrycod
 */

with source as (

    select * from {{ source('legacy', 'CTRYCOD') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        country_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(country_code_2) as country_code_2,
        trim(country_name) as country_name,
        trim(continent) as continent,
        trim(currency_code) as currency_code,
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
