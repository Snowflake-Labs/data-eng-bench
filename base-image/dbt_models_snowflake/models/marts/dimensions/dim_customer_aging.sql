{{
    config(
        materialized='table',
        tags=['dimension', 'aging', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_aging') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['aging_id']) }} AS aging_key,
        aging_id AS aging_id,

        -- Attributes
        customer_id,
        as_of_date,
        current_amount,
        days_30_amount,
        days_60_amount,
        days_90_amount,
        over_90_amount,
        total_balance,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE aging_id IS NOT NULL
)

SELECT * FROM final
