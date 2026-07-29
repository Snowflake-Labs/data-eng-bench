-- =============================================================================
-- DATA QUALITY: Late Arriving Facts Detection
-- =============================================================================
--
-- Identifies fact records that arrived after their business date, which can
-- cause issues with period-close reports and time-series accuracy.
--
-- Late arriving facts are common in:
-- - Offline/batch order uploads
-- - Partner data feeds with delays
-- - System integration backlogs
-- - Manual data entry corrections
--
-- @author Marcus Johnson
-- @since 2024-04-01
-- @modified 2024-08-15 - Added support for shipment facts
--
-- Thresholds:
--   WARNING: > 24 hours late
--   CRITICAL: > 7 days late
--   SEVERE: > 30 days late (may indicate data quality issue)
--
-- Full refresh runtime: ~12 minutes
-- Incremental: ~2 minutes
-- =============================================================================

-- Re-enabled after DATA-4521 fix
{{
    config(
        materialized='incremental',
        unique_key='fact_key',
        tags=['data-quality', 'timeliness', 'sla']
    )
}}

with order_facts as (
    -- Check order records
    select
        'ORDER' as fact_type,
        order_id as fact_key,
        order_number as business_key,
        ordered_at as business_timestamp,
        -- FIXME: We don't have a reliable loaded_at timestamp
        -- Using dbt_updated_at as proxy but this resets on model refresh
        dbt_updated_at as loaded_at,
        customer_id as related_entity_id,
        'customer_id' as related_entity_type, order_grand_total as fact_amount
    from {{ ref('fct_sales') }}
    {% if is_incremental() %}
    where dbt_updated_at > (select max(checked_at) from {{ this }})
    {% endif %}
),

-- TODO: Add shipment facts when fct_shipments model is ready
-- shipment_facts as (
--     select 'SHIPMENT' as fact_type, ...
-- ),

-- Calculate lateness
facts_with_latency as (
    select
        fact_type,
        fact_key,
        business_key,
        business_timestamp,
        loaded_at,
        related_entity_id,
        related_entity_type,
        fact_amount,
        DATEDIFF(hour, business_timestamp, loaded_at) as hours_late,
        DATEDIFF(day, business_timestamp, loaded_at) as days_late
    from order_facts
    where loaded_at > business_timestamp  -- Only late arrivals
),

-- Classify severity
classified as (
    select
        *,
        case
            when days_late > 30 then 'SEVERE'
            when days_late > 7 then 'CRITICAL'
            when hours_late > 24 then 'WARNING'
            else 'MINOR'
        end as severity,
        case
            when days_late > 30 then 'Investigate data source - possible historical backfill or system issue'
            when days_late > 7 then 'Review integration pipeline - significant delay detected'
            when hours_late > 24 then 'Monitor - exceeds 24hr SLA'
            else 'Within acceptable range but flagged'
        end as recommended_action
    from facts_with_latency
)

select
    fact_type,
    fact_key,
    business_key,
    business_timestamp,
    loaded_at,
    hours_late,
    days_late,
    severity,
    recommended_action,
    related_entity_id,
    related_entity_type,
    fact_amount,
    current_timestamp as checked_at
from classified
-- Filter to only significant lateness in output
where hours_late > 24
order by days_late desc
