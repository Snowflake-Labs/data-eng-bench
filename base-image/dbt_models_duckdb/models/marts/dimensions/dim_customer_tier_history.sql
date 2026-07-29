{{
    config(
        materialized='table',
        tags=['dimension', 'history', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_tier_history') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['tier_history_id']) }} AS history_key,
        tier_history_id AS history_id,
        
        -- Attributes
        customer_id,
        previous_tier_id,
        new_tier_id,
        change_reason,
        effective_date,
        points_at_change,
        spend_at_change,
        notes,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE tier_history_id IS NOT NULL
)

SELECT * FROM final
