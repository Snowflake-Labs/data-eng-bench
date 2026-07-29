{{
    config(
        materialized='view',
        unique_key='tier_id',
        tags=['staging', 'raw_sfdc', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ACCOUNT_TIERS_HIST') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TIER_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TIER_ID) AS tier_id,
        TRIM(TIER_CODE) AS tier_code,
        TRIM(TIER_NAME) AS tier_name,
        COALESCE(TIER_LEVEL, 0) AS tier_level,
        COALESCE(MIN_POINTS_REQUIRED, 0) AS min_points_required,
        COALESCE(MIN_SPEND_REQUIRED, 0) AS min_spend_required,
        COALESCE(POINTS_MULTIPLIER, 0) AS points_multiplier,
        COALESCE(DISCOUNT_PERCENTAGE, 0) AS discount_percentage,
        TRIM(FREE_SHIPPING) AS free_shipping,
        TRIM(BENEFITS_DESCRIPTION) AS benefits_description,
        TRIM(TIER_COLOR) AS tier_color,
        TRIM(TIER_ICON) AS tier_icon,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE TIER_ID IS NOT NULL
)

SELECT * FROM renamed
