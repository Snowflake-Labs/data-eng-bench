{{
    config(
        materialized='view',
        unique_key='wishlist_item_id',
        tags=['staging', 'raw_ga', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_ga', 'wishlists_hist') }}

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
        COALESCE(PRIORITY, 0) AS priority,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE WISHLIST_ITEM_ID IS NOT NULL
)

SELECT * FROM renamed
