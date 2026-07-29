{{
    config(
        materialized='table',
        tags=['dimension', 'policies', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_data_retention_policies') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['policy_id']) }} AS policies_key,
        policy_id AS policies_id,
        
        -- Attributes
        policy_name,
        entity_type,
        retention_days,
        action,
        is_active,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE policy_id IS NOT NULL
)

SELECT * FROM final
