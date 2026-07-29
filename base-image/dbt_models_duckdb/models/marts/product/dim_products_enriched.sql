/*
================================================================================
dim_products_enriched.sql

Author: Marcus Johnson
Created: 2023-07-15
Modified: 2024-09-22 by Sarah (added channel presence)

The "enriched" product dimension. Because apparently the regular product
dimension wasn't good enough for merchandising team. This model has gotten
completely out of hand with all the CTEs but nobody wants to touch it now.

Performance:
- Full refresh: 18 min (yes, really)
- Row count: ~125K products
- Peak memory: 96GB (!!!)
- DO NOT run during business hours

Incident History:
- 2024-01-15: OOM error crashed the warehouse. Had to switch to 2XL.
- 2024-06-20: Marketing added 15 new columns. Thanks marketing.
- 2024-08-03: Amazon integration broke channel detection. Fun times.

TODO: This needs to be refactored into smaller models. Volunteer?
TODO: Add Target marketplace when integration completes
FIXME: is_on_amazon returns true for products we delisted
HACK: Using hardcoded category_level because hierarchy table is broken
================================================================================
*/

with products as (
    select * from {{ ref('stg_product__products') }}
),

categories as (
    select * from {{ ref('stg_product__product_categories') }}
),

brands as (
    select * from {{ ref('stg_product__brands') }}
),

-- Enrich products with calculated pricing metrics
product_pricing as (
    select
        p.product_id,
        p.cost_price,
        p.wholesale_price,
        p.msrp,
        p.map_price,
        p.compare_at_price,
        p.clearance_price,
        p.promotional_price,
        -- Margin calculations
        case 
            when p.msrp > 0 and p.cost_price is not null 
            then round(100.0 * (p.msrp - p.cost_price) / p.msrp, 2)
            else null 
        end as gross_margin_pct,
        case 
            when p.cost_price > 0 
            then round(100.0 * (p.msrp - p.cost_price) / p.cost_price, 2)
            else null 
        end as markup_pct,
        -- Price positioning
        case
            when p.promotional_price is not null and p.promotional_price < p.msrp 
            then round(100.0 * (p.msrp - p.promotional_price) / p.msrp, 1)
            else 0 
        end as current_discount_pct,
        case
            when p.clearance_price is not null then 'Clearance'
            when p.promotional_price is not null then 'On Promotion'
            when p.compare_at_price is not null and p.compare_at_price > p.msrp then 'Marked Down'
            else 'Regular Price'
        end as price_status
    from products p
),

-- Product lifecycle and age analysis
product_lifecycle as (
    select
        p.product_id,
        p.lifecycle_status,
        p.launched_at,
        p.discontinued_at,
        p.last_sold_date,
        p.last_received_date,
        -- Days calculations
        date_diff('day', p.launched_at, current_date) as days_since_launch,
        date_diff('day', p.last_sold_date, current_date) as days_since_last_sale,
        date_diff('day', p.last_received_date, current_date) as days_since_last_receipt,
        -- Lifecycle stage classification
        case
            when p.discontinued_at is not null then 'Discontinued'
            when p.launched_at is null then 'Pre-Launch'
            when date_diff('day', p.launched_at, current_date) <= 90 then 'New Arrival'
            when date_diff('day', p.launched_at, current_date) <= 365 then 'Core Range'
            when date_diff('day', p.launched_at, current_date) <= 730 then 'Mature'
            else 'Legacy'
        end as lifecycle_stage,
        -- Activity indicators
        case 
            when p.last_sold_date is null then 'Never Sold'
            when date_diff('day', p.last_sold_date, current_date) > 180 then 'Dormant'
            when date_diff('day', p.last_sold_date, current_date) > 90 then 'Slow Moving'
            when date_diff('day', p.last_sold_date, current_date) > 30 then 'Moderate'
            else 'Active Seller'
        end as sales_velocity_status
    from products p
),

-- Inventory and fulfillment attributes
product_inventory_attrs as (
    select
        p.product_id,
        p.abc_classification,
        p.velocity_code,
        p.reorder_point,
        p.reorder_quantity,
        p.safety_stock,
        p.lead_time_days,
        p.days_of_supply,
        p.stockout_count_ytd,
        p.backorder_allowed,
        p.dropship_eligible,
        -- Inventory risk flags
        case 
            when p.stockout_count_ytd > 3 then 'High Stockout Risk'
            when p.stockout_count_ytd > 0 then 'Moderate Stockout Risk'
            else 'Low Risk'
        end as stockout_risk_level
    from products p
),

-- Channel availability
product_channels as (
    select
        p.product_id,
        p.shopify_product_id is not null as is_on_shopify,
        p.amazon_asin is not null as is_on_amazon,
        p.walmart_item_id is not null as is_on_walmart,
        p.google_product_id is not null as is_on_google_shopping,
        -- Count of active channels
        (case when p.shopify_product_id is not null then 1 else 0 end +
         case when p.amazon_asin is not null then 1 else 0 end +
         case when p.walmart_item_id is not null then 1 else 0 end +
         case when p.google_product_id is not null then 1 else 0 end) as active_channel_count
    from products p
),

-- Final enriched product dimension
final as (
    select
        -- Core product identifiers
        p.product_id,
        p.product_code,
        p.product_name,
        p.product_description,
        p.short_description,
        p.product_type,
        p.is_active,
        -- Brand information
        b.brand_id,
        b.brand_name,
        b.brand_code,
        b.is_private_label,
        -- Category hierarchy
        c.category_id,
        c.category_name,
        c.category_code,
        c.category_level,
        c.category_path,
        c.is_featured as is_featured_category,
        -- Physical attributes
        p.weight,
        p.weight_uom,
        p.weight_lbs,
        p.length_in,
        p.width_in,
        p.height_in,
        p.cubic_feet,
        p.base_uom,
        -- Product characteristics
        p.is_serialized,
        p.is_lot_tracked,
        p.is_perishable,
        p.shelf_life_days,
        p.warranty_months,
        p.country_of_origin,
        -- Pricing
        pp.cost_price,
        pp.wholesale_price,
        pp.msrp,
        pp.map_price,
        pp.compare_at_price,
        pp.clearance_price,
        pp.promotional_price,
        pp.gross_margin_pct,
        pp.markup_pct,
        pp.current_discount_pct,
        pp.price_status,
        -- Lifecycle
        pl.lifecycle_status,
        pl.lifecycle_stage,
        pl.launched_at,
        pl.discontinued_at,
        pl.days_since_launch,
        pl.days_since_last_sale,
        pl.sales_velocity_status,
        -- Inventory management
        pia.abc_classification,
        pia.velocity_code,
        pia.reorder_point,
        pia.safety_stock,
        pia.lead_time_days,
        pia.days_of_supply,
        pia.stockout_count_ytd,
        pia.stockout_risk_level,
        pia.backorder_allowed,
        pia.dropship_eligible,
        -- Channel presence
        pc.is_on_shopify,
        pc.is_on_amazon,
        pc.is_on_walmart,
        pc.is_on_google_shopping,
        pc.active_channel_count,
        -- SEO attributes
        p.meta_title,
        p.meta_description,
        p.canonical_url
    from products p
    left join categories c on p.primary_category_id = c.category_id
    left join brands b on p.brand_id = b.brand_id
    left join product_pricing pp on p.product_id = pp.product_id
    left join product_lifecycle pl on p.product_id = pl.product_id
    left join product_inventory_attrs pia on p.product_id = pia.product_id
    left join product_channels pc on p.product_id = pc.product_id
)

select * from final