{{
    config(
        materialized='table',
        tags=['dimension', 'packages', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_shipment_packages') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['package_id']) }} AS packages_key,
        package_id AS packages_id,
        
        -- Attributes
        shipment_id,
        package_number,
        tracking_number,
        weight,
        length,
        width,
        height,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE package_id IS NOT NULL
)

SELECT * FROM final
