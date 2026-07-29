{{
    config(
        materialized='view',

        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('audit', 'DATA_RETENTION_POLICIES') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY POLICY_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        POLICY_ID,
        POLICY_NAME,
        ENTITY_TYPE,
        RETENTION_DAYS,
        ACTION,
        IS_ACTIVE,
        CREATED_AT
    FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(POLICY_ID) AS policy_id,
        TRIM(POLICY_NAME) AS policy_name,
        TRIM(ENTITY_TYPE) AS entity_type,
        RETENTION_DAYS AS retention_days,
        TRIM(ACTION) AS action,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE POLICY_ID IS NOT NULL
)

SELECT * FROM renamed
