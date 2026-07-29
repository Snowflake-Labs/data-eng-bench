{{
    config(
        materialized='table',
        tags=['dimension', 'countries', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_countries') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['country_id']) }} AS countries_key,
        country_id AS countries_id,

        -- Attributes
        country_code_2,
        country_name,
        continent,
        currency_code,
        is_active,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE country_id IS NOT NULL
)

SELECT * FROM final
