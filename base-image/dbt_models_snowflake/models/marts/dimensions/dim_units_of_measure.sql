{{
    config(
        materialized='table',
        tags=['dimension', 'measure', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_units_of_measure') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['uom_code']) }} AS measure_key,
        uom_code AS measure_id,

        -- Attributes
        uom_name,
        uom_type,
        base_uom_code,
        conversion_factor,
        is_active,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE uom_code IS NOT NULL
)

SELECT * FROM final
