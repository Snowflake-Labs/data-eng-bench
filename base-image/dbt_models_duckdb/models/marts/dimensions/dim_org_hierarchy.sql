{{
    config(
        materialized='table',
        tags=['dimension', 'hierarchy', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_org_hierarchy') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['hierarchy_id']) }} AS hierarchy_key,
        hierarchy_id AS hierarchy_id,
        
        -- Attributes
        employee_id,
        manager_id,
        level,
        path,
        effective_from,
        effective_to,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE hierarchy_id IS NOT NULL
)

SELECT * FROM final
