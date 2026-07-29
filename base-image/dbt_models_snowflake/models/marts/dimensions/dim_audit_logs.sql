{{
    config(
        materialized='table',
        tags=['dimension', 'logs', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_audit_logs') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['audit_id']) }} AS logs_key,
        audit_id AS logs_id,

        -- Attributes
        event_type,
        event_timestamp,
        user_id,
        user_email,
        table_name,
        record_id,
        action,
        old_values,
        new_values,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE audit_id IS NOT NULL
)

SELECT * FROM final
