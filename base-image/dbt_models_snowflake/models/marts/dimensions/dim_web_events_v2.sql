{{
    config(
        materialized='table',
        tags=['dimension', 'events', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_web_events') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['event_id']) }} AS events_key,
        event_id AS events_id,

        -- Attributes
        session_id,
        event_type,
        event_name,
        event_timestamp,
        page_url,
        element_id,
        element_class,
        product_id,
        event_value,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE event_id IS NOT NULL
)

SELECT * FROM final
