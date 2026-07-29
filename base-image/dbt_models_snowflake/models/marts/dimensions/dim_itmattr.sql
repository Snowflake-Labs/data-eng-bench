{{
    config(
        materialized='table',
        tags=['dimension', 'itmattr', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_itmattr') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['attribute_id']) }} AS itmattr_key,
        attribute_id AS itmattr_id,

        -- Attributes
        attribute_code,
        attribute_name,
        attribute_description,
        attribute_type,
        data_type,
        is_variant_attribute,
        is_filterable,
        is_searchable,
        is_comparable,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE attribute_id IS NOT NULL
)

SELECT * FROM final
