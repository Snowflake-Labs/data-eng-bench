{{
    config(
        materialized='table',
        tags=['dimension', 'lines', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_trans_lines') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['variant_id']) }} AS lines_key,
        variant_id AS lines_id,

        -- Attributes
        order_id,
        line_number,
        variant_id,
        product_id,
        sku,
        product_name,
        variant_name,
        quantity_ordered,
        quantity_shipped,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE variant_id IS NOT NULL
)

SELECT * FROM final
