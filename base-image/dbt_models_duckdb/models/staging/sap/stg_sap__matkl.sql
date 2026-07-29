{{
    config(
        materialized='view',
        tags=['sap', 'staging']
    )
}}

/*
 * Staging model for RAW_SAP.MATKL
 *
 * Entity Type: table
 * Source: SAP - RAW_SAP.MATKL
 *
 * Purpose:
 *   - Standardize column names to snake_case
 *   - Apply data type casting where needed
 *   - Light cleansing (trim strings, handle nulls)
 *   - No business logic or joins at this layer
 *
 * Grain: One row per matkl
 */

with source as (

    select * from {{ source('sap', 'MATKL') }}

),

renamed as (

    select
        /*
         * Primary Key(s)
         */
        category_id,  -- Primary key

        /*
         * Business Columns
         */
        trim(category_code) as category_code,
        trim(category_name) as category_name,
        trim(category_description) as category_description,
        trim(parent_category_id) as parent_category_id,
        category_level as category_level,
        trim(category_path) as category_path,
        trim(category_path_ids) as category_path_ids,
        sort_order as sort_order,
        trim(image_url) as image_url,
        trim(icon_name) as icon_name,
        trim(meta_title) as meta_title,
        trim(meta_description) as meta_description,
        trim(meta_keywords) as meta_keywords,
        is_featured as is_featured,
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
