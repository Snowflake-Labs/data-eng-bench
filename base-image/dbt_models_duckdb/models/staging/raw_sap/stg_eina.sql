{{
    config(
        materialized='view',
        unique_key='_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'EINA') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(_ID) AS _id,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_SOURCE_TABLE) AS _source_table,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE _ID IS NOT NULL
)

SELECT * FROM renamed
