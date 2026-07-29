{{
    config(
        materialized='table',
        tags=['dimension', 'codes', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_reason_codes') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['reason_code_id']) }} AS codes_key,
        reason_code_id AS codes_id,

        -- Attributes
        entity_type,
        reason_code,
        reason_name,
        reason_description,
        requires_notes,
        is_active,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE reason_code_id IS NOT NULL
)

SELECT * FROM final
