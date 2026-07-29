{{
    config(
        materialized='table',
        tags=['dimension', 'segments', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_segments') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['segment_id']) }} AS segments_key,
        segment_id AS segments_id,
        
        -- Attributes
        segment_code,
        segment_name,
        segment_type,
        segment_description,
        segment_criteria,
        is_dynamic,
        refresh_frequency,
        last_refreshed_at,
        member_count,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE segment_id IS NOT NULL
)

SELECT * FROM final
