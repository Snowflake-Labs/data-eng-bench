{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_SEGMENTS') }}

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
        UPDATED_AT
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
        UPDATED_AT AS updated_at
    FROM deduplicated
    WHERE SEGMENT_ID IS NOT NULL
)

SELECT * FROM renamed
