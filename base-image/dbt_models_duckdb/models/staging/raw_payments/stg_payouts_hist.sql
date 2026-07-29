{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_payments', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PAYOUTS_HIST') }}
    
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
        _archived_at AS _archived_at
    FROM cleaned
    WHERE _ID IS NOT NULL
)

SELECT * FROM renamed
