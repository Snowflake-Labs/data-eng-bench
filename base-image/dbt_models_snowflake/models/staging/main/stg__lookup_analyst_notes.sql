{{
    config(
        materialized='view',

        tags=['staging', 'main', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', '_lookup_analyst_notes') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        id AS id,
        TRIM(text_value) AS text_value
    FROM cleaned
    WHERE id IS NOT NULL
)

SELECT * FROM renamed
