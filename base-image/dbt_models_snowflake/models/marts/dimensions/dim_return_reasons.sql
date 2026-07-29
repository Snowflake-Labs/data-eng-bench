{{
    config(
        materialized='table',
        tags=['dimension', 'reasons', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_return_reasons') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['reason_id']) }} AS reasons_key,
        reason_id AS reasons_id,

        -- Attributes
        reason_code,
        reason_name,
        reason_description,
        is_active,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE reason_id IS NOT NULL
)

SELECT * FROM final
