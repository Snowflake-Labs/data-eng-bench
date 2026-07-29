{{
    config(
        materialized='view',
        unique_key='shipping_method_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'TSHM_HIST') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY SHIPPING_METHOD_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(SHIPPING_METHOD_ID) AS shipping_method_id,
        TRIM(SHIPPING_METHOD_CODE) AS shipping_method_code,
        TRIM(SHIPPING_METHOD_NAME) AS shipping_method_name,
        TRIM(CARRIER_ID) AS carrier_id,
        COALESCE(ESTIMATED_DAYS_MIN, 0) AS estimated_days_min,
        COALESCE(ESTIMATED_DAYS_MAX, 0) AS estimated_days_max,
        IS_EXPRESS AS is_express,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        _archived_at AS _archived_at
    FROM cleaned
    WHERE SHIPPING_METHOD_ID IS NOT NULL
)

SELECT * FROM renamed
