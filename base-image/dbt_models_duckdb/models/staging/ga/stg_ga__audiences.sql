{{
    config(
        materialized='view',
        tags=['ga', 'staging']
    )
}}

/*
 * Staging model for RAW_GA.AUDIENCES
 *
 * Entity Type: table
 * Source: GA - RAW_GA.AUDIENCES
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per audiences
 */

with source as (

    select * from {{ source('ga', 'AUDIENCES') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        segment_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(segment_code) as segment_code,
        trim(segment_name) as segment_name,
        trim(segment_type) as segment_type,
        trim(segment_description) as segment_description,
        segment_criteria as segment_criteria,
        is_dynamic as is_dynamic,
        trim(refresh_frequency) as refresh_frequency,
        last_refreshed_at as last_refreshed_at,
        member_count as member_count,
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
