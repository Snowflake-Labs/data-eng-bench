{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('orders', 'SHIPPING_METHODS') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY SHIPPING_METHOD_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT * FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(SHIPPING_METHOD_ID) AS shipping_method_id,
        TRIM(SHIPPING_METHOD_CODE) AS shipping_method_code,
        TRIM(SHIPPING_METHOD_NAME) AS shipping_method_name,
        TRIM(CARRIER_ID) AS carrier_id,
        COALESCE(ESTIMATED_DAYS_MIN, 0) AS estimated_days_min,
        COALESCE(ESTIMATED_DAYS_MAX, 0) AS estimated_days_max,
        IS_EXPRESS AS is_express,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE SHIPPING_METHOD_ID IS NOT NULL
)

SELECT * FROM renamed
