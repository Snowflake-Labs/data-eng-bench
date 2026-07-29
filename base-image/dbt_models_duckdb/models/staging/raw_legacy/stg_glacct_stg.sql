{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'GLACCT_STG') }}
    
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
        TRIM(_ROW_HASH) AS _row_hash,
        TRIM(_status) AS _status
    FROM cleaned
    WHERE _ID IS NOT NULL
)

SELECT * FROM renamed
