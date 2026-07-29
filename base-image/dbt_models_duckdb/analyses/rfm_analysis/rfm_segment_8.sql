-- RFM Segment 8 Analysis
-- Analyzes customers in RFM segment 8

with customer_rfm as (
    select
        customer_id,
        full_name,
        recency_days,
        frequency_score,
        monetary_score,
        rfm_segment
    from { ref('int_customers__rfm_scores') }
    where rfm_segment = '888'  -- Example: 111, 222, etc.
),

segment_metrics as (
    select
        '8' as segment_number,
        count(*) as customer_count,
        round(avg(recency_days), 1) as avg_recency_days,
        round(avg(frequency_score), 2) as avg_frequency,
        round(avg(monetary_score), 2) as avg_monetary_value,
        case
            when '8' in ('5', '4') then 'High Value'
            when '8' in ('3') then 'Medium Value'
            else 'Lower Value'
        end as segment_value_tier
    from customer_rfm
),

recommendations as (
    select
        *,
        case
            when '8' = '5' then 'VIP Treatment - Reward loyalty, personalized service'
            when '8' = '4' then 'Engage - Upsell and cross-sell opportunities'
            when '8' = '3' then 'Nurture - Regular communication and promotions'
            when '8' = '2' then 'Reactivate - Win-back campaigns'
            else 'Monitor - Basic engagement'
        end as recommended_action
    from segment_metrics
)

select * from recommendations
