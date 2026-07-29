{{
    config(
        materialized='table',
        tags=['dimension', 'positions', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_employee_positions') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['assignment_id']) }} AS positions_key,
        assignment_id AS positions_id,

        -- Attributes
        employee_id,
        position_id,
        start_date,
        end_date,
        is_primary,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE assignment_id IS NOT NULL
)

SELECT * FROM final
