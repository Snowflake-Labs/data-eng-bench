{{
    config(
        materialized='table',
        tags=['dimension', 'costs', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_product_costs') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['cost_id']) }} AS costs_key,
        cost_id AS costs_id,

        -- Attributes
        variant_id,
        supplier_id,
        cost_type,
        unit_cost,
        currency_code,
        effective_from,
        effective_to,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE cost_id IS NOT NULL
)

SELECT * FROM final
