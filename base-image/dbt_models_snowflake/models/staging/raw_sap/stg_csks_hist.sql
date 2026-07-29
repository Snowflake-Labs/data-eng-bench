{{
    config(
        materialized='view',
        unique_key='cost_center_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'CSKS_HIST') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY COST_CENTER_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(COST_CENTER_ID) AS cost_center_id,
        TRIM(COST_CENTER_CODE) AS cost_center_code,
        TRIM(COST_CENTER_NAME) AS cost_center_name,
        TRIM(MANAGER_ID) AS manager_id,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM deduplicated
    WHERE COST_CENTER_ID IS NOT NULL
)

SELECT * FROM renamed
