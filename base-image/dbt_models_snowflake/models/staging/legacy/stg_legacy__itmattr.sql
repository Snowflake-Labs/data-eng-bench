{{
    config(
        materialized='view',
        tags=['legacy', 'staging']
    )
}}

/*
 * Staging model for RAW_LEGACY.ITMATTR
 *
 * Entity Type: table
 * Source: LEGACY - RAW_LEGACY.ITMATTR
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per itmattr
 */

with source as (

    select * from {{ source('legacy', 'ITMATTR') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        attribute_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(attribute_code) as attribute_code,
        trim(attribute_name) as attribute_name,
        trim(attribute_description) as attribute_description,
        trim(attribute_type) as attribute_type,
        trim(data_type) as data_type,
        is_variant_attribute as is_variant_attribute,
        is_filterable as is_filterable,
        is_searchable as is_searchable,
        is_comparable as is_comparable,
        is_required as is_required,
        trim(default_value) as default_value,
        trim(validation_regex) as validation_regex,
        trim(min_value) as min_value,
        trim(max_value) as max_value,
        display_order as display_order,
        trim(attribute_group) as attribute_group,
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
