-- Campaign Effectiveness Analysis
-- Measures campaign performance across key metrics

with campaign_metrics as (
    select
        c.campaign_id,
        c.campaign_name,
        c.channel,
        c.actual_spend,
        c.impressions,
        c.clicks,
        c.conversions as campaign_conversions,
        count(distinct s.order_id) as actual_orders,
        count(distinct s.customer_id) as customers_acquired,
        sum(s.line_total) as revenue_generated
    from {{ ref('stg_marketing__marketing_campaigns') }} c
    left join {{ ref('fct_sales') }} s
        on c.campaign_id = s.campaign_id
        and s.is_cancelled = false
    group by c.campaign_id, c.campaign_name, c.channel, c.actual_spend, c.impressions, c.clicks, c.conversions
),

effectiveness_calc as (
    select
        campaign_id,
        campaign_name,
        channel,
        round(actual_spend, 2) as spend,
        impressions,
        clicks,
        campaign_conversions,
        actual_orders,
        customers_acquired,
        round(revenue_generated, 2) as revenue,
        round((revenue_generated - actual_spend), 2) as net_profit,
        round(100.0 * clicks / nullif(impressions, 0), 2) as ctr_pct,
        round(100.0 * actual_orders / nullif(clicks, 0), 2) as conversion_rate_pct,
        round(actual_spend / nullif(clicks, 0), 2) as cost_per_click,
        round(actual_spend / nullif(actual_orders, 0), 2) as cost_per_acquisition,
        round(revenue_generated / nullif(actual_spend, 0), 2) as roas,
        round(100.0 * (revenue_generated - actual_spend) / nullif(actual_spend, 0), 2) as roi_pct
    from campaign_metrics
),

final as (
    select
        *,
        case
            when roi_pct > 200 then 'Excellent'
            when roi_pct > 100 then 'Very Good'
            when roi_pct > 50 then 'Good'
            when roi_pct > 0 then 'Break Even'
            else 'Loss'
        end as effectiveness_rating
    from effectiveness_calc
)

select * from final
order by roi_pct desc
