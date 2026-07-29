{{
    config(
        materialized='table',
        tags=['dimension', 'geography', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_dim_geography') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['geography_key']) }} AS geography_key,
        geography_key AS geography_id,
        
        -- Attributes
        country_code,
        country_name,
        state_code,
        state_name,
        city,
        postal_code,
        region,
        timezone,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE geography_key IS NOT NULL
)

SELECT * FROM final
