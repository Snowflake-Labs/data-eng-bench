{{
    config(
        materialized='table',
        tags=['dimension', 'methods', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_payment_methods') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['payment_method_code']) }} AS methods_key,
        payment_method_code AS methods_id,

        -- Attributes
        payment_method_code,
        payment_method_name,
        is_electronic,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE payment_method_code IS NOT NULL
)

SELECT * FROM final
