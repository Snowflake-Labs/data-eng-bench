{{
    config(
        materialized='table',
        tags=['dimension', 'departments', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_store_departments') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['department_id']) }} AS departments_key,
        department_id AS departments_id,

        -- Attributes
        store_id,
        department_code,
        department_name,
        floor,
        is_active,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE department_id IS NOT NULL
)

SELECT * FROM final
