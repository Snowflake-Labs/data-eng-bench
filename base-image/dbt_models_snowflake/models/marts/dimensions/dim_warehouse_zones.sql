{{
    config(
        materialized='table',
        tags=['dimension', 'zones', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_warehouse_zones') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['zone_id']) }} AS zones_key,
        zone_id AS zones_id,

        -- Attributes
        warehouse_id,
        zone_code,
        zone_name,
        zone_type,
        temperature_controlled,
        min_temperature,
        max_temperature,
        capacity_units,
        sort_order,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE zone_id IS NOT NULL
)

SELECT * FROM final
