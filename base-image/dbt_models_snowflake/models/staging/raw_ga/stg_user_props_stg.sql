{{
    config(
        materialized='view',
        unique_key='preference_id',
        tags=['staging', 'raw_ga', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_ga', 'user_props_stg') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PREFERENCE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(PREFERENCE_ID) AS preference_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(PREFERENCE_CATEGORY) AS preference_category,
        TRIM(PREFERENCE_KEY) AS preference_key,
        TRIM(PREFERENCE_VALUE) AS preference_value,
        IS_OPTED_IN AS is_opted_in,
        TRIM(EFFECTIVE_FROM) AS effective_from,
        TRIM(EFFECTIVE_TO) AS effective_to,
        TRIM(SOURCE) AS source,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        trim(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        TRIM("_status") AS _status
    FROM cleaned
    WHERE PREFERENCE_ID IS NOT NULL
)

SELECT * FROM renamed
