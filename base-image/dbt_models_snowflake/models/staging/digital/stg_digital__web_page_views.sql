{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.WEB_PAGE_VIEWS

with source as (
    select * from {{ source('digital', 'WEB_PAGE_VIEWS') }}
),

renamed as (
    select
        trim(page_view_id) as page_view_id,
        trim(session_id) as session_id,
        trim(page_url) as page_url,
        trim(page_title) as page_title,
        trim(page_type) as page_type,
        trim(product_id) as product_id,
        trim(category_id) as category_id,
        view_timestamp,
        time_on_page_seconds,
        scroll_depth_percent,
        created_at
    from source
)

select * from renamed
