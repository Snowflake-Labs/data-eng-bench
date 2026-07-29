{{
    config(
        materialized='table',
        tags=['dimension', 'cancellations', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_order_cancellations') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['cancellation_id']) }} AS cancellations_key,
        cancellation_id AS cancellations_id,
        
        -- Attributes
        order_id,
        reason_code,
        reason_text,
        cancelled_by,
        cancelled_at,
        refund_amount,
        
        -- Audit
        CURRENT_TIMESTAMP AS dw_created_at,
        CURRENT_TIMESTAMP AS dw_updated_at
        
    FROM source
    WHERE cancellation_id IS NOT NULL
)

SELECT * FROM final
