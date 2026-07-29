{{
    config(
        materialized='table',
        tags=['dimension', 'logs', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_user_access_logs') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['access_id']) }} AS logs_key,
        access_id AS logs_id,

        -- Attributes
        user_id,
        user_email,
        access_type,
        access_timestamp,
        ip_address,
        user_agent,
        location,
        success,
        failure_reason,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE access_id IS NOT NULL
)

SELECT * FROM final
