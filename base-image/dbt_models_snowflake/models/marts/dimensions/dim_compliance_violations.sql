{{
    config(
        materialized='table',
        tags=['dimension', 'violations', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_compliance_violations') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['violation_id']) }} AS violations_key,
        violation_id AS violations_id,

        -- Attributes
        rule_id,
        detected_at,
        entity_type,
        entity_id,
        description,
        severity,
        status,
        resolved_by,
        resolved_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE violation_id IS NOT NULL
)

SELECT * FROM final
