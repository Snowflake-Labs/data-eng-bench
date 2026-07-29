{{
    config(
        materialized='view',
        tags=['intermediate', 'sales']
    )
}}

-- int_sales__order_lines
-- order line item details from SAP VBAP and POS
-- why do we have two sources? ask dave from IT, it's his fault

-- PERF: This view is fine but downstream joins can be slow
-- Consider materializing if fct_sales build time exceeds 1hr

-- HACK: TRY_CAST everywhere because SAP sends garbage sometimes
-- FIXME: POS line_total occasionally negative due to system bug - see DATA-445

with sap_order_lines as (

    select
        order_line_id,
        order_id,
        line_number,
        product_id,
        sku,
        product_name,
        variant_name,
        quantity_ordered::decimal(10,2) as quantity_ordered,
        quantity_shipped::decimal(10,2) as quantity_shipped,
        TRY_CAST(unit_price AS decimal(18,2)) as unit_price,
        (quantity_ordered * TRY_CAST(unit_price AS decimal(18,2)))::decimal(18,2) as extended_price,
        TRY_CAST(discount_amount AS decimal(18,2)) as discount_amount,
        TRY_CAST(tax_amount AS decimal(18,2)) as tax_amount,
        TRY_CAST(line_total AS decimal(18,2)) as line_total,
        'SAP' as source_system
    from {{ ref('stg_sap__vbap') }}

),

pos_order_lines as (

    select
        order_line_id,
        order_id,
        line_number,
        product_id,
        sku,
        product_name,
        variant_name,
        quantity_ordered::decimal(10,2) as quantity_ordered,
        quantity_shipped::decimal(10,2) as quantity_shipped,
        TRY_CAST(unit_price AS decimal(18,2)) as unit_price,
        (quantity_ordered * TRY_CAST(unit_price AS decimal(18,2)))::decimal(18,2) as extended_price,
        TRY_CAST(discount_amount AS decimal(18,2)) as discount_amount,
        TRY_CAST(tax_amount AS decimal(18,2)) as tax_amount,
        TRY_CAST(line_total AS decimal(18,2)) as line_total,
        'POS' as source_system
    from {{ ref('stg_pos__trans_lines') }}

),

all_order_lines as (

    select * from sap_order_lines
    union all
    select * from pos_order_lines

),

final as (

    select
        order_line_id,
        order_id,
        line_number,
        product_id,
        sku,
        product_name,
        variant_name,
        source_system,

        -- Quantities
        quantity_ordered,
        quantity_shipped, quantity_ordered - quantity_shipped as quantity_backorder,

        -- Amounts
        unit_price,
        extended_price,
        discount_amount,
        tax_amount,
        line_total,

        -- Calculated metrics
        case
            when extended_price > 0
            then (discount_amount / extended_price)
            else 0
        end as discount_rate,

        case
            when quantity_ordered > 0
            then (extended_price / quantity_ordered)
            else 0
        end as avg_unit_price,

        -- Flags
        case
            when quantity_shipped >= quantity_ordered then true
            else false
        end as is_fully_shipped

    from all_order_lines

)

select * from final
