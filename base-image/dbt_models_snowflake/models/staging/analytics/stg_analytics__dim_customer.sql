{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

{#
    Staging model for ANALYTICS.DIM_CUSTOMER (SCD Type 2)

    Pulls customer dimension from SAP BW analytics export.
    Linda from Finance uses this for quarterly board reports.

    Business rules:
    - tier_name is NULL for B2B customers (they don't participate in loyalty)
    - is_current = TRUE means this is the active record for the customer

    TODO: 2024-03-15 Switch to incremental - DATA-1401
    FIXME: 2023-11-20 customer_number format changed, need to handle both

    INCIDENT: 2023-08-15 - SAP BW extract job failed for 3 days,
              data was stale. Added Slack alerts after this.

    DEPRECATED: The old stg_customers_v1 model should not be used anymore
#}

-- DEPRECATED: stg_customers_v1 is replaced by this model

WITH source AS (
    SELECT * FROM {{ source('analytics', 'DIM_CUSTOMER') }}
),

-- Single responsibility: just rename and clean
renamed AS (
    SELECT
        customer_key,
        TRIM(customer_id) AS customer_id,
        trim(customer_number) as customer_number,  -- format changed in 2023, ugh
        TRIM(customer_name) AS customer_name,
        trim(customer_type) as customer_type,
        -- Business rule: NULL for B2B customers, not a bug
        trim(tier_name) as tier_name,
        TRIM(segment_name) AS segment_name,
        trim(city) as city,
        TRIM(state) as state,
        trim(country) as country,
        is_active,
        effective_from,
        effective_to,
        is_current
    FROM source
),

final AS (
    SELECT * FROM renamed
)

SELECT * FROM final

-- DEBUG: Check for duplicate customer_keys (shouldn't happen but SAP...)
-- SELECT customer_key, COUNT(*) FROM final GROUP BY 1 HAVING COUNT(*) > 1
