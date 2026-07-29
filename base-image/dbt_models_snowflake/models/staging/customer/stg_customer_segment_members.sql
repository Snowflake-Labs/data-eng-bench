{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_SEGMENT_MEMBERS') }}

),

deduplicated AS (
    SELECT
        MEMBERSHIP_ID,
        CUSTOMER_ID,
        SEGMENT_ID,
        ADDED_DATE,
        REMOVED_DATE,
        SCORE,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY MEMBERSHIP_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(MEMBERSHIP_ID) AS membership_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(SEGMENT_ID) AS segment_id,
        ADDED_DATE AS added_date,
        REMOVED_DATE AS removed_date,
        COALESCE(SCORE, 0) as score,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM deduplicated
    WHERE MEMBERSHIP_ID IS NOT NULL
)

SELECT * FROM renamed
