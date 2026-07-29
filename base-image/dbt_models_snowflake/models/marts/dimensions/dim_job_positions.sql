{{
    config(
        materialized='table',
        tags=['dimension', 'positions', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_job_positions') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['position_id']) }} AS positions_key,
        position_id AS positions_id,

        -- Attributes
        position_code,
        position_title,
        department_id,
        job_level,
        min_salary,
        max_salary,
        is_active,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE position_id IS NOT NULL
)

SELECT * FROM final
