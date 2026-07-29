{{
    config(
        materialized='table',
        tags=['dimension', 'views', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_web_page_views') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['page_view_id']) }} AS views_key,
        page_view_id AS views_id,
        
        -- Attributes
        session_id,
        page_url,
        page_title,
        page_type,
        product_id,
        category_id,
        view_timestamp,
        time_on_page_seconds,
        scroll_depth_percent,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE page_view_id IS NOT NULL
)

SELECT * FROM final
