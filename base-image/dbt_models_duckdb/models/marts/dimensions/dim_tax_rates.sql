{{
    config(
        materialized='table',
        tags=['dimension', 'rates', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_tax_rates') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['tax_rate_id']) }} AS rates_key,
        tax_rate_id AS rates_id,
        
        -- Attributes
        tax_code,
        tax_name,
        tax_type,
        rate,
        country_code,
        state_code,
        effective_from,
        effective_to,
        is_active,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE tax_rate_id IS NOT NULL
)

SELECT * FROM final
