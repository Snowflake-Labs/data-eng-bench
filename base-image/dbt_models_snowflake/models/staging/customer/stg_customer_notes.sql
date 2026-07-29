{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_NOTES') }}

),

deduplicated AS (
    SELECT
        NOTE_ID,
        CUSTOMER_ID,
        NOTE_TYPE,
        NOTE_SUBJECT,
        NOTE_CONTENT,
        IS_PINNED,
        IS_INTERNAL_ONLY,
        RELATED_ENTITY_TYPE,
        RELATED_ENTITY_ID,
        CREATED_AT,
        UPDATED_AT,
        CREATED_BY,
        UPDATED_BY
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY NOTE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(NOTE_ID) AS note_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(NOTE_TYPE) AS note_type,
        TRIM(NOTE_SUBJECT) AS note_subject,
        TRIM(NOTE_CONTENT) AS note_content,
        IS_PINNED AS is_pinned,
        IS_INTERNAL_ONLY AS is_internal_only,
        TRIM(RELATED_ENTITY_TYPE) AS related_entity_type,
        TRIM(RELATED_ENTITY_ID) AS related_entity_id,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        TRIM(CREATED_BY) AS created_by,
        TRIM(UPDATED_BY) AS updated_by
    FROM deduplicated
    WHERE NOTE_ID IS NOT NULL
)

SELECT * FROM renamed
