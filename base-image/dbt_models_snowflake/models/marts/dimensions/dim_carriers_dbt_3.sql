{{
    config(
        materialized='table',
        tags=['dimension', 'carriers', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_carriers') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['carrier_id']) }} AS carriers_key,
        carrier_id AS carriers_id,
        
        -- Attributes
        carrier_code,
        carrier_name,
        carrier_type,
        tracking_url_template,
        api_endpoint,
        is_active,
        created_at,
        updated_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE carrier_id IS NOT NULL
)

SELECT * FROM final
