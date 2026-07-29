{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.SUPPLIER_PERFORMANCE_SCORES

with source as (
    select * from {{ source('procurement', 'SUPPLIER_PERFORMANCE_SCORES') }}
),

renamed as (
    select
        trim(score_id) as score_id,
        trim(supplier_id) as supplier_id,
        period_date,
        quality_score,
        delivery_score,
        price_score,
        service_score,
        overall_score,
        created_at
    from source
)

select * from renamed
