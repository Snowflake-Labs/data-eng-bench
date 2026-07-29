{{
    config(
        materialized='view',
        unique_key='department_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'HRP1000_DEP') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY DEPARTMENT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(DEPARTMENT_ID) AS department_id,
        TRIM(DEPARTMENT_CODE) AS department_code,
        TRIM(DEPARTMENT_NAME) AS department_name,
        TRIM(PARENT_DEPARTMENT_ID) AS parent_department_id,
        TRIM(MANAGER_ID) AS manager_id,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE DEPARTMENT_ID IS NOT NULL
)

SELECT * FROM renamed
