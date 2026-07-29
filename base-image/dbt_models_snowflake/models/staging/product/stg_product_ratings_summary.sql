{{
    config(
        materialized='view',

        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'PRODUCT_RATINGS_SUMMARY') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(SUMMARY_ID) AS summary_id,
        TRIM(PRODUCT_ID) AS product_id,
        COALESCE(TOTAL_REVIEWS, 0) AS total_reviews,
        COALESCE(AVERAGE_RATING, 0) AS average_rating,
        COALESCE(RATING_1_COUNT, 0) AS rating_1_count,
        COALESCE(RATING_2_COUNT, 0) AS rating_2_count,
        COALESCE(RATING_3_COUNT, 0) AS rating_3_count,
        COALESCE(RATING_4_COUNT, 0) AS rating_4_count,
        COALESCE(RATING_5_COUNT, 0) AS rating_5_count,
        COALESCE(RECOMMEND_PERCENTAGE, 0) AS recommend_percentage,
        LAST_REVIEW_DATE AS last_review_date,
        LAST_CALCULATED_AT AS last_calculated_at
    FROM cleaned
    WHERE SUMMARY_ID IS NOT NULL
)

SELECT * FROM renamed
