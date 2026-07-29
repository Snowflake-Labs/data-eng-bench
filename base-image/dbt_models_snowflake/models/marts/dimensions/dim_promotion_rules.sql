{{
    config(
        materialized='table',
        tags=['dimension', 'rules', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_promotion_rules') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['rule_id']) }} AS rules_key,
        rule_id AS rules_id,

        -- Attributes
        promotion_id,
        rule_type,
        rule_operator,
        rule_value,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE rule_id IS NOT NULL
)

SELECT * FROM final
