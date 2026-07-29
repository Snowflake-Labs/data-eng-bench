{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_RESERVATIONS') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(RESERVATION_ID) AS reservation_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(RESERVATION_TYPE) AS reservation_type,
        TRIM(REFERENCE_TYPE) AS reference_type,
        TRIM(REFERENCE_ID) AS reference_id,
        QUANTITY_RESERVED AS quantity_reserved,
        TRIM(STATUS) AS status,
        COALESCE(PRIORITY, 0) AS priority,
        RESERVED_AT AS reserved_at,
        EXPIRES_AT AS expires_at,
        TRIM(CREATED_BY) AS created_by
    FROM cleaned
    WHERE RESERVATION_ID IS NOT NULL
)

SELECT * FROM renamed
