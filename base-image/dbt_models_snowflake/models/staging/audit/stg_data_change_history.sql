{{
    config(
        materialized='view',

        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('audit', 'DATA_CHANGE_HISTORY') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(CHANGE_ID) AS change_id,
        TRIM(TABLE_NAME) AS table_name,
        TRIM(RECORD_ID) AS record_id,
        TRIM(COLUMN_NAME) AS column_name,
        TRIM(OLD_VALUE) AS old_value,
        TRIM(NEW_VALUE) AS new_value,
        TRIM(CHANGE_TYPE) AS change_type,
        TRIM(CHANGED_BY) AS changed_by,
        CHANGED_AT AS changed_at
    FROM cleaned
    WHERE CHANGE_ID IS NOT NULL
)

SELECT * FROM renamed
