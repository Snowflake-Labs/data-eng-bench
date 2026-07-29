{{
    config(
        materialized='table',
        tags=['dimension', 'accounts', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_chart_of_accounts') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['account_id']) }} AS accounts_key,
        account_id AS accounts_id,
        
        -- Attributes
        account_number,
        account_name,
        account_type,
        account_subtype,
        parent_account_id,
        is_active,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE account_id IS NOT NULL
)

SELECT * FROM final
