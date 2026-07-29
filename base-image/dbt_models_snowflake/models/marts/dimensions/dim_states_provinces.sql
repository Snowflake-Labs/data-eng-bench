{{
    config(
        materialized='table',
        tags=['dimension', 'provinces', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_states_provinces') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['state_province_id']) }} AS provinces_key,
        state_province_id AS provinces_id,

        -- Attributes
        country_id,
        state_code,
        state_name,
        is_active,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE state_province_id IS NOT NULL
)

SELECT * FROM final
