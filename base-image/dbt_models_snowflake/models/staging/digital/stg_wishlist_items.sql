{{
    config(
        materialized='view',

        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'WISHLIST_ITEMS') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(WISHLIST_ITEM_ID) AS wishlist_item_id,
        TRIM(WISHLIST_ID) AS wishlist_id,
        TRIM(VARIANT_ID) AS variant_id,
        ADDED_AT AS added_at,
        TRIM(NOTES) AS notes,
        COALESCE(PRIORITY, 0) AS priority
    FROM cleaned
    WHERE WISHLIST_ITEM_ID IS NOT NULL
)

SELECT * FROM renamed
