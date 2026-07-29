{{
    config(
        materialized='table',
        tags=['dimension', 'summary', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_product_ratings_summary') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['summary_id']) }} AS summary_key,
        summary_id AS summary_id,

        -- Attributes
        product_id,
        total_reviews,
        average_rating,
        rating_1_count,
        rating_2_count,
        rating_3_count,
        rating_4_count,
        rating_5_count,
        recommend_percentage,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE summary_id IS NOT NULL
)

SELECT * FROM final
