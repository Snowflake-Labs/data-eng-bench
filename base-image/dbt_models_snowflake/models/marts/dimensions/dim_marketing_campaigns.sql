{{
    config(
        materialized='table',
        tags=['dimension', 'campaigns', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_marketing_campaigns') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['campaign_id']) }} AS campaigns_key,
        campaign_id AS campaigns_id,

        -- Attributes
        campaign_code,
        campaign_name,
        campaign_type,
        start_date,
        end_date,
        budget,
        status,
        created_at,
        updated_at,

        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at

    FROM source
    WHERE campaign_id IS NOT NULL
)

SELECT * FROM final
