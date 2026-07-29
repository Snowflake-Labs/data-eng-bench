{{
    config(
        materialized='table',
        tags=['dimension', 'periods', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_gl_periods') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['period_id']) }} AS periods_key,
        period_id AS periods_id,

        -- Attributes
        fiscal_year,
        fiscal_quarter,
        fiscal_month,
        period_name,
        start_date,
        end_date,
        status,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE period_id IS NOT NULL
)

SELECT * FROM final
