-- Marketing Conversion Funnel Analysis
-- Tracks customer journey from awareness to purchase

with funnel_stages as (
    select
        customer_id,
        max(case when event_type = 'page_view' then 1 else 0 end) as reached_awareness,
        max(case when event_type = 'product_view' then 1 else 0 end) as reached_interest,
        max(case when event_type = 'cart_add' then 1 else 0 end) as reached_consideration,
        max(case when event_type = 'purchase' then 1 else 0 end) as reached_purchase
    from {{ ref('stg_customer__customer_lifecycle_events') }}
    group by customer_id
),

funnel_metrics as (
    select
        sum(reached_awareness) as awareness_count,
        sum(reached_interest) as interest_count,
        sum(reached_consideration) as consideration_count,
        sum(reached_purchase) as purchase_count
    from funnel_stages
),

funnel_conversion_rates as (
    select
        'Awareness' as stage,
        awareness_count as customers,
        100.0 as conversion_rate_from_previous,
        round(100.0 * purchase_count / nullif(awareness_count, 0), 2) as conversion_to_purchase_pct
    from funnel_metrics

    union all

    select
        'Interest' as stage,
        interest_count as customers,
        round(100.0 * interest_count / nullif(awareness_count, 0), 2) as conversion_rate_from_previous,
        round(100.0 * purchase_count / nullif(interest_count, 0), 2) as conversion_to_purchase_pct
    from funnel_metrics

    union all

    select
        'Consideration' as stage,
        consideration_count as customers,
        round(100.0 * consideration_count / nullif(interest_count, 0), 2) as conversion_rate_from_previous,
        round(100.0 * purchase_count / nullif(consideration_count, 0), 2) as conversion_to_purchase_pct
    from funnel_metrics

    union all

    select
        'Purchase' as stage,
        purchase_count as customers,
        round(100.0 * purchase_count / nullif(consideration_count, 0), 2) as conversion_rate_from_previous,
        100.0 as conversion_to_purchase_pct
    from funnel_metrics
)

select * from funnel_conversion_rates
order by customers desc
