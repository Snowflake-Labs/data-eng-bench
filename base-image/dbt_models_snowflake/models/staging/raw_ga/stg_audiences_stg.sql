{{
    config(
        materialized='view',
        unique_key='segment_id',
        tags=['staging', 'raw_ga', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'AUDIENCES_STG') }}

),

deduplicated AS (
    SELECT
        SEGMENT_ID,
        SEGMENT_CODE,
        SEGMENT_NAME,
        SEGMENT_TYPE,
        SEGMENT_DESCRIPTION,
        SEGMENT_CRITERIA,
        IS_DYNAMIC,
        REFRESH_FREQUENCY,
        LAST_REFRESHED_AT,
        MEMBER_COUNT,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID,
        _ROW_NUMBER,
        _ROW_HASH,
        _status
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY SEGMENT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(SEGMENT_ID) AS segment_id,
        TRIM(SEGMENT_CODE) AS segment_code,
        TRIM(SEGMENT_NAME) AS segment_name,
        TRIM(SEGMENT_TYPE) AS segment_type,
        TRIM(SEGMENT_DESCRIPTION) AS segment_description,
        SEGMENT_CRITERIA AS segment_criteria,
        IS_DYNAMIC AS is_dynamic,
        TRIM(REFRESH_FREQUENCY) AS refresh_frequency,
        LAST_REFRESHED_AT AS last_refreshed_at,
        COALESCE(MEMBER_COUNT, 0) AS member_count,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
    FROM deduplicated
    WHERE SEGMENT_ID IS NOT NULL
)

SELECT * FROM renamed
