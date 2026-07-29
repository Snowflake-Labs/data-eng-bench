/*
================================================================================
ORPHANED: Denormalized Product Dimension
================================================================================
Created: 2022-05-10
Original purpose: Looker Explore performance optimization

This was created when Looker was slow. Then we upgraded Looker.
Then we forgot this existed. Then it kept running for 2 years.

Someone noticed it in a cost audit but we're afraid to delete it
because "what if something breaks?"

Spoiler: Nothing uses it. We checked. But still scared.
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['orphaned', 'denormalized', 'afraid_to_delete'],
        meta={
            'owner': 'unassigned',
            'original_purpose': 'Looker performance',
            'confirmed_unused': true,
            'deletion_blocked_by': 'Fear of the unknown'
        }
    )
}}

-- This entire model is probably unnecessary now
-- But deleting things in production is scary

SELECT
    p.product_id,
    p.sku,
    p.product_name,
    p.description,
    p.category_id,
    p.brand_id,
    p.unit_price,
    p.cost_price,
    p.status,

    -- Denormalized category info (now available in Looker natively)
    c.category_name,
    c.category_level_1,
    c.category_level_2,
    c.category_level_3,

    -- Denormalized brand info
    b.brand_name,
    b.brand_tier,

    -- Pre-calculated margins (Looker can do this now)
    p.unit_price - p.cost_price AS unit_margin,
    (p.unit_price - p.cost_price) / NULLIF(p.unit_price, 0) AS margin_percent,

    CURRENT_TIMESTAMP AS _denormalized_at

FROM {{ ref('dim_products') }} p
LEFT JOIN {{ ref('dim_categories') }} c ON p.category_id = c.category_id
LEFT JOIN {{ ref('dim_brands') }} b ON p.brand_id = b.brand_id
