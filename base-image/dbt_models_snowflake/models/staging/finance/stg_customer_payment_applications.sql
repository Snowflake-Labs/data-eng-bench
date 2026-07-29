{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'CUSTOMER_PAYMENT_APPLICATIONS') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(APPLICATION_ID) AS application_id,
        TRIM(PAYMENT_ID) AS payment_id,
        TRIM(INVOICE_ID) AS invoice_id,
        AMOUNT_APPLIED AS amount_applied,
        APPLIED_AT AS applied_at
    FROM cleaned
    WHERE APPLICATION_ID IS NOT NULL
)

SELECT * FROM renamed
