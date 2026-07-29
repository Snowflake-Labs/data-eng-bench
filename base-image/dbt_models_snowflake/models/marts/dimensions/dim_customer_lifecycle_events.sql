{{
    config(
        materialized='table',
        tags=['dimension', 'events', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_lifecycle_events') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['event_id']) }} AS events_key,
        event_id AS events_id,

        -- Attributes
        customer_id,
        event_type,
        event_date,
        event_timestamp,
        previous_status,
        new_status,
        event_trigger,
        event_details,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE event_id IS NOT NULL
)

SELECT * FROM final
