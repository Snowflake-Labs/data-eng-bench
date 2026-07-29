{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_wms', 'CARRIERS') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CARRIER_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT * FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CARRIER_ID) AS carrier_id,
        TRIM(CARRIER_CODE) AS carrier_code,
        TRIM(CARRIER_NAME) AS carrier_name,
        TRIM(CARRIER_TYPE) AS carrier_type,
        TRIM(TRACKING_URL_TEMPLATE) AS tracking_url_template,
        TRIM(API_ENDPOINT) AS api_endpoint,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE CARRIER_ID IS NOT NULL
)

SELECT * FROM renamed
