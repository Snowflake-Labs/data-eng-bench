{{
    config(
        materialized='table',
        tags=['dimension', 'languages', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_languages') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['language_code']) }} AS languages_key,
        language_code AS languages_id,

        -- Attributes
        language_name,
        native_name,
        is_active,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE language_code IS NOT NULL
)

SELECT * FROM final
