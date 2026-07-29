{{
    config(
        materialized='view',
        
        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'FACT_INVENTORY') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(INVENTORY_KEY) AS inventory_key,
        DATE_KEY AS date_key,
        COALESCE(PRODUCT_KEY, 0) AS product_key,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        COALESCE(QUANTITY_ON_HAND, 0) AS quantity_on_hand,
        COALESCE(QUANTITY_AVAILABLE, 0) AS quantity_available,
        COALESCE(QUANTITY_RESERVED, 0) AS quantity_reserved,
        COALESCE(QUANTITY_INCOMING, 0) AS quantity_incoming,
        COALESCE(UNIT_COST, 0) AS unit_cost,
        COALESCE(TOTAL_VALUE, 0) AS total_value
    FROM cleaned
    WHERE WAREHOUSE_ID IS NOT NULL
)

SELECT * FROM renamed
