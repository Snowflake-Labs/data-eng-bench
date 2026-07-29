{{
    config(
        materialized='table',
        tags=['dimension', 'preferences', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_preferences') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['preference_id']) }} AS preferences_key,
        preference_id AS preferences_id,
        
        -- Attributes
        customer_id,
        preference_category,
        preference_key,
        preference_value,
        is_opted_in,
        effective_from,
        effective_to,
        source,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE preference_id IS NOT NULL
)

SELECT * FROM final
