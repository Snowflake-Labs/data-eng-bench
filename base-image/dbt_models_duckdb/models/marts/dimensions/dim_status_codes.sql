{{
    config(
        materialized='table',
        tags=['dimension', 'codes', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_status_codes') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['status_code_id']) }} AS codes_key,
        status_code_id AS codes_id,
        
        -- Attributes
        entity_type,
        status_code,
        status_name,
        status_description,
        display_order,
        is_terminal,
        is_active,
        created_at,
        updated_at,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE status_code_id IS NOT NULL
)

SELECT * FROM final
