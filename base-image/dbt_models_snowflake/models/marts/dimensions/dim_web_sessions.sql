{{
    config(
        materialized='table',
        tags=['dimension', 'sessions', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_web_sessions') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['session_id']) }} AS sessions_key,
        session_id AS sessions_id,

        -- Attributes
        visitor_id,
        customer_id,
        channel_id,
        session_start,
        session_end,
        duration_seconds,
        page_views,
        landing_page,
        exit_page,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE session_id IS NOT NULL
)

SELECT * FROM final
