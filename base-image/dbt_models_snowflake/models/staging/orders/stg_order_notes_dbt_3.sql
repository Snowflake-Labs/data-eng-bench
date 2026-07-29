{{
    config(
        materialized='view',

        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_sfdc', 'order_notes') }}

),

deduplicated AS (
    SELECT
        NOTE_ID,
        ORDER_ID,
        NOTE_TYPE,
        NOTE_TEXT,
        IS_INTERNAL,
        CREATED_BY,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY NOTE_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(NOTE_ID) AS note_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(NOTE_TYPE) AS note_type,
        TRIM(NOTE_TEXT) AS note_text,
        IS_INTERNAL AS is_internal,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE NOTE_ID IS NOT NULL
)

SELECT * FROM renamed
