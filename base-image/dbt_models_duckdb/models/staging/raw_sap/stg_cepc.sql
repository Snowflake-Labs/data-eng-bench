{{
    config(
        materialized='view',
        unique_key='profit_center_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CEPC') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PROFIT_CENTER_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PROFIT_CENTER_ID) AS profit_center_id,
        TRIM(PROFIT_CENTER_CODE) AS profit_center_code,
        TRIM(PROFIT_CENTER_NAME) AS profit_center_name,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE PROFIT_CENTER_ID IS NOT NULL
)

SELECT * FROM renamed
