{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ORDER_MODIFICATIONS') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(MODIFICATION_ID) AS modification_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(MODIFICATION_TYPE) AS modification_type,
        TRIM(FIELD_NAME) AS field_name,
        TRIM(OLD_VALUE) AS old_value,
        TRIM(NEW_VALUE) AS new_value,
        TRIM(MODIFIED_BY) AS modified_by,
        MODIFIED_AT AS modified_at,
        TRIM(REASON) AS reason
    FROM cleaned
    WHERE MODIFICATION_ID IS NOT NULL
)

SELECT * FROM renamed
