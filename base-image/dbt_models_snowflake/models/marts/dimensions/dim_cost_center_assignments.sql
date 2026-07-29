{{
    config(
        materialized='table',
        tags=['dimension', 'assignments', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_cost_center_assignments') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['assignment_id']) }} AS assignments_key,
        assignment_id AS assignments_id,

        -- Attributes
        employee_id,
        cost_center_id,
        allocation_percentage,
        effective_from,
        effective_to,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE assignment_id IS NOT NULL
)

SELECT * FROM final
