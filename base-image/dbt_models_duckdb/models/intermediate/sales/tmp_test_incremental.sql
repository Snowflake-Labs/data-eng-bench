-- TEMP: Testing incremental strategy before applying to int_sales__orders_enriched
-- Delete this file after confirming merge strategy works
-- @author Marcus - 2024-11-01

{{ config(materialized='view', enabled=false) }}

select 1 as test
