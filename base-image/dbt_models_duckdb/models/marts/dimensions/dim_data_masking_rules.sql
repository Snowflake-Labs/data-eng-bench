{{
    config(
        materialized='table',
        tags=['dimension', 'rules', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_data_masking_rules') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['rule_id']) }} AS rules_key,
        rule_id AS rules_id,
        
        -- Attributes
        table_name,
        column_name,
        masking_type,
        is_active,
        created_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE rule_id IS NOT NULL
)

SELECT * FROM final
