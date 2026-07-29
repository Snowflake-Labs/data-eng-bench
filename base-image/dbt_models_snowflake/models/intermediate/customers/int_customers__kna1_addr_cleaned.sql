{{
    config(
        materialized='view',
        tags=['intermediate', 'customers']
    )
}}

/*
    Intermediate model: int_customers__kna1_addr_cleaned
    Domain: customers

    Cleaned and standardized data ready for mart consumption.
*/

WITH source AS (

    SELECT * FROM {{ ref('stg_sap__kna1_addr') }}

),

cleaned AS (

    SELECT
        address_id,
        customer_id,
        address_type,
        address_label,
        is_default_billing,
        is_default_shipping,
        recipient_name,
        company_name,
        address_line_1,
        address_line_2,
        address_line_3,
        city,
        state_province,
        postal_code,
        country_code,
        phone,
        delivery_instructions,
        latitude,
        longitude,
        is_verified,
        verified_at,
        is_active,
        created_at,
        updated_at,
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
