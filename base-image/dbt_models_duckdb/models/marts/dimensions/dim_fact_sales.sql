{{
    config(
        materialized='table',
        tags=['dimension', 'sales', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_fact_sales') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['sale_key']) }} AS sales_key,
        sale_key AS sales_id,
        
        -- Attributes
        date_key,
        time_key,
        customer_key,
        product_key,
        employee_key,
        channel_key,
        geography_key,
        order_id,
        order_line_id,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE sale_key IS NOT NULL
)

SELECT * FROM final
