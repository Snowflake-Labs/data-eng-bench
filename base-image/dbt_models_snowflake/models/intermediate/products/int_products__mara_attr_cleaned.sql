{{
    config(
        materialized='view',
        tags=['intermediate', 'products', 'sap', 'mdm'],
        meta={
            'owner': 'product-data@company.com',
            'sla': '4:00am UTC',
            'estimated_runtime_minutes': 1,
            'snowflake_warehouse': 'TRANSFORM_S',
            'mdm_source': 'SAP_MDG',
            'refresh_frequency': 'daily',
            'downstream_dependencies': ['dim_products', 'dim_product_attributes']
        }
    )
}}

/*
================================================================================
Intermediate model: int_products__mara_attr_cleaned
Domain: products
Source: SAP MARA (Material Master) - Attribute Extension
================================================================================

Product attribute definitions from SAP Master Data.
These define what attributes are available for products (not the values).

KNOWN ISSUES:
- attribute_group values inconsistent between SAP instances
- validation_regex may contain SAP-specific patterns that don't work in Snowflake
- ~50 attributes have is_active=false but are still used in legacy products

Code Review Comments (preserved for context):
- Marcus (2023-04-01): "Why do we need validation_regex if we're not validating?"
- Sarah (2023-04-01): "PIM team uses it, keep it for compatibility"
- Jake (2024-05-20): "display_order has gaps (10, 20, 30...) - is that intentional?"
- Marcus (2024-05-20): "SAP thing. They leave gaps for future insertions."
================================================================================
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_sap__mara_attr') }}

),

cleaned AS (

    SELECT
        attribute_id,
        attribute_code,
        attribute_name,
        attribute_description,
        attribute_type,
        data_type,
        is_variant_attribute,
        is_filterable,
        is_searchable,
        is_comparable,
        is_required,
        default_value,
        validation_regex,
        min_value,
        max_value,
        display_order,
        attribute_group,
        is_active,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
