{{
    config(
        materialized='table',
        tags=['dimension', 'notes', 'scd_type_1']
    )
}}

WITH source AS (
    SELECT * FROM {{ ref('stg_customer_notes') }}
),

final AS (
    SELECT
        {{ dbt_utils.generate_surrogate_key(['note_id']) }} AS notes_key,
        note_id AS notes_id,

        -- Attributes
        customer_id,
        note_type,
        note_subject,
        note_content,
        is_pinned,
        is_internal_only,
        related_entity_type,
        related_entity_id,
        created_at,

        -- Audit
        CURRENT_TIMESTAMP() AS dw_created_at,
        CURRENT_TIMESTAMP() AS dw_updated_at

    FROM source
    WHERE note_id IS NOT NULL
)

SELECT * FROM final
