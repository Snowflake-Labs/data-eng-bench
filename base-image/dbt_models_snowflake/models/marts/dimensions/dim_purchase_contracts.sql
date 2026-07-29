{{
    config(
        materialized='table',
        tags=['dimension', 'contracts', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_purchase_contracts') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['contract_id']) }} AS contracts_key,
        contract_id AS contracts_id,

        -- Attributes
        contract_number,
        supplier_id,
        contract_type,
        start_date,
        end_date,
        total_value,
        status,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE contract_id IS NOT NULL
)

SELECT * FROM final
