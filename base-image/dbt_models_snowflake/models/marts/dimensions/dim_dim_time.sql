{{
    config(
        materialized='table',
        tags=['dimension', 'time', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_dim_time') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['time_key']) }} AS time_key,
        time_key AS time_id,

        -- Attributes
        full_time,
        hour,
        minute,
        second,
        am_pm,
        hour_12,
        time_of_day,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE time_key IS NOT NULL
)

SELECT * FROM final
