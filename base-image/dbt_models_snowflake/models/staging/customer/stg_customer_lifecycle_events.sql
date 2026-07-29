{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_LIFECYCLE_EVENTS') }}

),

deduplicated AS (
    SELECT
        EVENT_ID,
        CUSTOMER_ID,
        EVENT_TYPE,
        EVENT_DATE,
        EVENT_TIMESTAMP,
        PREVIOUS_STATUS,
        NEW_STATUS,
        EVENT_TRIGGER,
        EVENT_DETAILS,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EVENT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(EVENT_ID) AS event_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(EVENT_TYPE) AS event_type,
        EVENT_DATE AS event_date,
        EVENT_TIMESTAMP AS event_timestamp,
        TRIM(PREVIOUS_STATUS) AS previous_status,
        TRIM(NEW_STATUS) AS new_status,
        TRIM(EVENT_TRIGGER) AS event_trigger,
        EVENT_DETAILS AS event_details,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE EVENT_ID IS NOT NULL
)

SELECT * FROM renamed
