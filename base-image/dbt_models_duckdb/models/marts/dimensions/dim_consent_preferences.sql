{{
    config(
        materialized='table',
        tags=['dimension', 'preferences', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_consent_preferences') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['preference_id']) }} AS preferences_key,
        preference_id AS preferences_id,
        
        -- Attributes
        customer_id,
        consent_type,
        is_consented,
        consent_date,
        ip_address,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE preference_id IS NOT NULL
)

SELECT * FROM final
