{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'COST_CENTERS') }}

),

cleaned AS (
    SELECT
        COST_CENTER_ID,
        COST_CENTER_CODE,
        COST_CENTER_NAME,
        MANAGER_ID,
        IS_ACTIVE,
        CREATED_AT
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
        CREATED_AT AS created_at
    FROM cleaned
    WHERE COST_CENTER_ID IS NOT NULL
)

SELECT * FROM renamed
