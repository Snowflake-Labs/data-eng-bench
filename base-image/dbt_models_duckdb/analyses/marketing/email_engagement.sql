-- Email Engagement Analysis
-- Analyzes email campaign performance and engagement patterns

with email_metrics as (
    select
        email_id,
        campaign_id,
        send_date,
        recipients_count,
        opens_count,
        clicks_count,
        bounces_count,
        unsubscribes_count,
        round(100.0 * opens_count / nullif(recipients_count, 0), 2) as open_rate,
        round(100.0 * clicks_count / nullif(opens_count, 0), 2) as click_through_rate,
        round(100.0 * bounces_count / nullif(recipients_count, 0), 2) as bounce_rate,
        round(100.0 * unsubscribes_count / nullif(recipients_count, 0), 2) as unsubscribe_rate
    from {{ ref('stg_sfdc__email_campaigns') }}
),

engagement_segments as (
    select
        date_trunc('month', send_date) as send_month,
        count(*) as emails_sent,
        sum(recipients_count) as total_recipients,
        sum(opens_count) as total_opens,
        sum(clicks_count) as total_clicks,
        round(avg(open_rate), 2) as avg_open_rate,
        round(avg(click_through_rate), 2) as avg_ctr,
        round(avg(bounce_rate), 2) as avg_bounce_rate,
        round(avg(unsubscribe_rate), 2) as avg_unsubscribe_rate,
        sum(case when open_rate >= 25 then 1 else 0 end) as high_performing_emails,
        sum(case when open_rate < 10 then 1 else 0 end) as low_performing_emails
    from email_metrics
    group by date_trunc('month', send_date)
)

select
    send_month,
    emails_sent,
    total_recipients,
    total_opens,
    total_clicks,
    avg_open_rate,
    avg_ctr,
    avg_bounce_rate,
    avg_unsubscribe_rate,
    high_performing_emails,
    low_performing_emails,
    round(100.0 * high_performing_emails / emails_sent, 2) as pct_high_performing
from engagement_segments
order by send_month desc
