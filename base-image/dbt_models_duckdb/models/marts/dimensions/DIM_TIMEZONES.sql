{{
    config(
        materialized='table',
        tags=['dimension', 'timezones', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_timezones') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['timezone_id']) }} AS timezones_key,
        timezone_id AS timezones_id,
        
        -- Attributes
        timezone_name,
        utc_offset,
        uses_dst,
        is_active,
        created_at,
        updated_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE timezone_id IS NOT NULL
)

SELECT * FROM final
