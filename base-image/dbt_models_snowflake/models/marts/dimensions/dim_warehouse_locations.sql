{{
    config(
        materialized='table',
        tags=['dimension', 'locations', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_warehouse_locations') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['location_id']) }} AS locations_key,
        location_id AS locations_id,

        -- Attributes
        warehouse_id,
        zone_id,
        location_code,
        location_barcode,
        aisle,
        rack,
        shelf,
        location_type,
        is_pickable,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE location_id IS NOT NULL
)

SELECT * FROM final
