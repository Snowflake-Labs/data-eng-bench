/*
TEMPORARY DEBUG MODEL
Created: 2024-10-15 by Sarah Chen
Purpose: Investigating order duplication issue (INC-5521)

This model isolates orders that appear duplicated after the
Shopify webhook migration. DO NOT include in production runs.

Delete after investigation complete.
*/

{# DISABLED 2025-01-12: Investigation complete, INC-5521 resolved #}
{{
    config(
        materialized='view',
        enabled=false,
        tags=['debug', 'temporary', 'do-not-deploy']
    )
}}

-- Finding potential duplicate orders based on:
-- 1. Same customer_id
-- 2. Same total within 1 minute
-- 3. Same item count

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

-- HACK: Quick and dirty duplicate detection
potential_dupes as (
    select
        o1.order_id as order_id_1,
        o2.order_id as order_id_2,
        o1.customer_id,
        o1.grand_total,
        o1.ordered_at as ordered_at_1,
        o2.ordered_at as ordered_at_2,
        abs(datediff('second', o1.ordered_at, o2.ordered_at)) as seconds_apart
    from orders o1
    inner join orders o2
        on o1.customer_id = o2.customer_id
        and o1.grand_total = o2.grand_total
        and o1.order_id < o2.order_id  -- Prevent self-join dupes
        and abs(datediff('second', o1.ordered_at, o2.ordered_at)) < 60
)

select * from potential_dupes
order by ordered_at_1 desc
