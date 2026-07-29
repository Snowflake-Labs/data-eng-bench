{{
    config(
        materialized='table',
        tags=['dimension', 'interactions', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_fact_customer_interactions') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['interaction_key']) }} AS interactions_key,
        interaction_key AS interactions_id,
        
        -- Attributes
        date_key,
        time_key,
        customer_key,
        employee_key,
        channel_key,
        interaction_type,
        duration_seconds,
        satisfaction_score,
        resolved,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE interaction_key IS NOT NULL
)

SELECT * FROM final
