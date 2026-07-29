{{
    config(
        materialized='table',
        tags=['dimension', 'members', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_segment_members') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['membership_id']) }} AS members_key,
        membership_id AS members_id,
        
        -- Attributes
        customer_id,
        segment_id,
        added_date,
        removed_date,
        score,
        is_active,
        created_at,
        updated_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE membership_id IS NOT NULL
)

SELECT * FROM final
