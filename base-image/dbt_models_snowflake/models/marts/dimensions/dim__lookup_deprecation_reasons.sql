{{
    config(
        materialized='table',
        tags=['dimension', 'reasons', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg__lookup_deprecation_reasons') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['id']) }} AS reasons_key,
        id AS reasons_id,

        -- Attributes
        text_value,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE id IS NOT NULL
)

SELECT * FROM final
