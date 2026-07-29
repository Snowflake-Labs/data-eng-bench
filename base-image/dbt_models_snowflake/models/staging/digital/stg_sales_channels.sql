{{
    config(
        materialized='view',

        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'SALES_CHANNELS') }}

),

deduplicated AS (
    SELECT
        CHANNEL_ID,
        CHANNEL_CODE,
        CHANNEL_NAME,
        CHANNEL_TYPE,
        IS_ACTIVE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CHANNEL_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(CHANNEL_CODE) AS channel_code,
        TRIM(CHANNEL_NAME) AS channel_name,
        TRIM(CHANNEL_TYPE) AS channel_type,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE CHANNEL_ID IS NOT NULL
)

SELECT * FROM renamed
