{{
    config(
        materialized='view',
        tags=['orders', 'staging', 'core', 'pii', 'sla-critical'],
        meta={
            'owner': 'orders-platform@company.com',
            'team': 'data-platform',
            'SLA': 'T+0 (CDC)',
            'pii_columns': ['ip_address', 'user_agent', 'billing_address_id', 'shipping_address_id'],
            'data_classification': 'confidential',
            'refresh_frequency': 'realtime',
            'downstream_dashboards': ['exec_orders_overview', 'ops_fulfillment_tracker', 'finance_daily_revenue'],
            'row_count_expected': '~2.4M',
            'avg_runtime_seconds': 12.7
        }
    )
}}

/*
================================================================================
  stg_orders__orders.sql
  Staging model for ORDERS.ORDERS - the backbone of all order analytics
================================================================================

  @description    Primary staging model for all customer orders. Transforms raw
                  OMS data into clean, typed columns for downstream consumption.
                  This is one of our most critical models - treat with care.

  @source         orders.ORDERS (OMS via Fivetran CDC)
                  Historical: SQL Server direct conn (deprecated 2021-03)

  @author         wei.zhang@company.com (original, 2019-06-14)
  @author         sarah.chen@company.com (AS400 migration, 2020-02-18)
  @author         marcus.johnson@company.com (fraud columns, 2021-02-03)
  @author         priya.patel@company.com (attribution expansion, 2022-07-20)
  @author         tyler.brooks@company.com (customer snapshot cols, 2023-05-11)

  @version        4.7.2
  @last_modified  2024-11-18

================================================================================
  VERSION HISTORY
================================================================================
  v1.0.0  2019-06-14  wei.zhang       Initial staging model from direct SQL Server
  v1.1.0  2019-09-22  wei.zhang       Added exchange_rate handling for intl orders
  v2.0.0  2020-02-18  sarah.chen      AS400 migration - added legacy columns
  v2.1.0  2020-04-30  sarah.chen      Fixed legacy_order_id dupes (DATA-1247)
  v2.2.0  2020-08-15  wei.zhang       Third-party ID columns (Shopify, Stripe)
  v3.0.0  2021-02-03  marcus.johnson  Fraud detection columns post-incident
  v3.1.0  2021-06-20  marcus.johnson  Added ip_fraud_score, chargeback_flag
  v3.2.0  2021-09-14  sarah.chen      NetSuite integration columns
  v3.3.0  2021-12-08  wei.zhang       Loop returns integration (replacing Returnly)
  v4.0.0  2022-07-20  priya.patel     UTM/attribution tracking expansion
  v4.1.0  2022-10-05  priya.patel     First/last touch campaign fields
  v4.2.0  2023-01-19  tyler.brooks    Compliance columns (PCI, export control)
  v4.3.0  2023-05-11  tyler.brooks    Customer snapshot at order time
  v4.4.0  2023-08-28  priya.patel     Fixed UTM parsing for encoded params
  v4.5.0  2024-02-14  wei.zhang       Affirm checkout integration
  v4.6.0  2024-06-03  tyler.brooks    Added analyst_review fields
  v4.7.0  2024-09-17  sarah.chen      Performance optimization for large date ranges
  v4.7.1  2024-10-22  marcus.johnson  Hotfix: null handling in fraud_score
  v4.7.2  2024-11-18  wei.zhang       Documentation refresh

================================================================================
  CODE REVIEW HISTORY (from GitHub/GitLab)
================================================================================
  PR #1247 (2020-02-18) - AS400 Migration
    - @wei.zhang: "Do we really need ALL these legacy columns? Seems excessive"
    - @sarah.chen: "Finance team requires them for 7-year audit trail. Non-negotiable."
    - @marcus.johnson: "Can we at least deprecate old_order_number eventually?"
    - @sarah.chen: "Added to backlog (DATA-1892). Target: 2025 after AS400 sunset."
    - @wei.zhang: "LGTM with that caveat. Merging."

  PR #2341 (2021-02-03) - Fraud Columns
    - @priya.patel: "Why is fraud_score a float? Shouldn't it be integer 0-100?"
    - @marcus.johnson: "ML model outputs 0.0-1.0 probability. Converting loses precision."
    - @sarah.chen: "Agree with Marcus. Also adding ip_fraud_score separately."
    - @tyler.brooks: "Can we add index on fraud_score for dashboard filtering?"
    - @marcus.johnson: "It's a view - indexes won't help. Mart models handle that."
    - @priya.patel: "Fair point. Approved."

  PR #3892 (2022-07-20) - Attribution Expansion
    - @tyler.brooks: "10 new columns seems like a lot. Performance impact?"
    - @priya.patel: "Tested on prod mirror - adds <0.5s to full table scan"
    - @wei.zhang: "Marketing team has been asking for this for 18 months..."
    - @sarah.chen: "About time! LGTM"
    - @marcus.johnson: "Should we normalize UTM params to lowercase?"
    - @priya.patel: "Good catch - added lower() to utm_source/medium. Others stay as-is per marketing."

  PR #5621 (2023-05-11) - Customer Snapshot
    - @priya.patel: "Why snapshot customer data here vs joining in marts?"
    - @tyler.brooks: "Point-in-time accuracy. Customer segments change, order doesn't."
    - @wei.zhang: "This was a HUGE pain to backfill. Let's document that."
    - @sarah.chen: "Backfill took 3 days. Worth it for cohort accuracy though."
    - @marcus.johnson: "Approved. Good defensive modeling."

================================================================================
  KNOWN ISSUES & TECHNICAL DEBT
================================================================================
  DATA-1892  (Open, P3)     legacy_channel_code has ~2.3% unmapped values
                            Workaround: COALESCE to 'UNKNOWN' in marts
                            Owner: sarah.chen, Target: 2025-Q1

  DATA-2341  (Open, P2)     exchange_rate is NULL for ~0.8% of intl orders
                            pre-2020-06. Using daily avg as fallback in int_orders.
                            Owner: wei.zhang, Blocked on Finance approval

  DATA-3156  (Open, P4)     old_order_number format inconsistent (some have
                            leading zeros stripped). Not worth fixing - deprecating.
                            Owner: none assigned

  DATA-4521  (Closed)       fraud_score was returning negative values for
                            some edge cases. Fixed in v4.7.1 with GREATEST(0, x)
                            Owner: marcus.johnson, Fixed: 2024-10-22

  DATA-5102  (Open, P2)     utm_campaign truncated at 255 chars, some
                            marketing campaigns use longer names (why??)
                            Owner: priya.patel, Target: 2024-Q4

================================================================================
  INCIDENT HISTORY
================================================================================
  INC-2021-0142  (2021-01-28)  Fraud incident - $340K in chargebacks over 2 weeks
                               Root cause: No fraud scoring in place
                               Resolution: Added fraud_* columns in v3.0.0
                               Post-mortem: https://wiki/incidents/INC-2021-0142

  INC-2022-0089  (2022-03-15)  Orders dashboard showing 0 revenue for 6 hours
                               Root cause: Fivetran sync failure, NULL grand_total
                               Resolution: Added COALESCE and alerting
                               Post-mortem: https://wiki/incidents/INC-2022-0089

  INC-2023-0201  (2023-09-08)  Customer LTV calculations off by ~15%
                               Root cause: customer_ltv_at_order not backfilled
                               Resolution: 3-day backfill, added validation test
                               Post-mortem: https://wiki/incidents/INC-2023-0201

================================================================================
  PERFORMANCE NOTES
================================================================================
  - Average runtime: 12.7s (full refresh), 0.3s (incremental via CDC)
  - Row count: ~2.4M orders (as of 2024-11)
  - Growth rate: ~15K orders/day
  - Peak load: Black Friday (~180K orders/day)
  - Downstream dependencies: 47 models (14 marts, 8 intermediates)
  - Consider: Partitioning by ordered_at if performance degrades >20s

================================================================================
  BUSINESS RULES & ASSUMPTIONS
================================================================================
  1. order_id is the unique identifier (UUID from OMS)
  2. order_number is human-readable, format: ORD-YYYYMMDD-XXXXX
  3. Orders with status='CANCELLED' should still be included (for reporting)
  4. test_order_flag=true orders are excluded in most marts (but kept here)
  5. exchange_rate: 1.0 for USD, varies for international
  6. grand_total = subtotal - discount_total + shipping_total + tax_total
  7. Fraud review required if fraud_score > 0.7 (per policy FRD-001)
  8. PII columns (ip_address, user_agent) masked in prod for non-admin users

================================================================================
  DEPENDENCIES
================================================================================
  Upstream:   {{ source('orders', 'ORDERS') }}
  Downstream: int_orders__enriched, int_orders__with_items,
              fct_orders, dim_order_status, kpi_sales__daily_revenue

================================================================================
*/

-- HACK: 2024-02-14 wei.zhang - Affirm orders sometimes have NULL customer_id
-- for guest checkout. Need to handle this until Affirm fixes their webhook.
-- Tracking in DATA-5523

-- TODO: 2024-06-03 tyler.brooks - Add is_subscription_order flag once subscription
-- system goes live (expected 2025-Q1). Talked to product team.

-- FIXME: 2023-11-02 sarah.chen - Some legacy orders have future dates due to
-- timezone bugs in AS400. Should clamp to migration_date but need Finance sign-off.

-- NOTE: If you're debugging order discrepancies, check the exclude_from_reporting
-- and test_order_flag columns FIRST. Learned this the hard way... - marcus

with source as (
    SELECT * from {{ source('orders', 'ORDERS') }}
    -- DEBUG: Uncomment below to test specific order issues
    -- where order_id = 'test-order-id-here'
),

-- ============================================================================
-- Main transformation: renamed and cleaned columns
-- Sarah: I know this is a lot of columns, sorry. Blame Finance requirements.
-- ============================================================================
renamed AS (
    select
        -- ====================================================================
        -- PRIMARY KEYS & IDENTIFIERS
        -- These are the core lookup columns. order_id is the source of truth.
        -- ====================================================================
        trim(order_id) as order_id,  -- UUID from OMS, never null
        trim(order_number) AS order_number,  -- Human readable: ORD-YYYYMMDD-XXXXX
        TRIM(customer_id) as customer_id,  -- FK to dim_customers, can be NULL for guest
        trim(order_type) AS order_type,  -- STANDARD, REPLACEMENT, EXCHANGE, B2B
        TRIM(order_source) as order_source,  -- WEB, MOBILE_APP, PHONE, POS, API

        -- ====================================================================
        -- CHANNEL & LOCATION
        -- Added channel_id in 2020 for multi-channel attribution
        -- ====================================================================
        trim(channel_id) as channel_id,  -- FK to dim_channels
        TRIM(currency_code) AS currency_code,  -- ISO 4217: USD, EUR, GBP, etc
        exchange_rate,  -- Rate to USD at time of order (NULL pre-2020-06, see DATA-2341)
        trim(billing_address_id) AS billing_address_id,  -- FK to dim_addresses (PII)
        TRIM(shipping_address_id) as shipping_address_id,  -- FK to dim_addresses (PII)

        -- ====================================================================
        -- FINANCIAL COLUMNS
        -- All amounts in source currency. Convert via exchange_rate for USD.
        -- Wei: Please don't change the order of these, some downstream models
        -- depend on column position (I know, I know... it's on the backlog)
        -- ====================================================================
        subtotal,  -- Sum of line items before discounts
        discount_total,  -- Total discounts applied (coupons, promos, etc)
        shipping_total,  -- Shipping charges
        tax_total,  -- Sales tax / VAT
        grand_total,  -- Final customer-facing total

        -- Cost & margin columns (added 2021 by Finance team)
        cost_of_goods,  -- COGS from inventory system
        gross_margin,  -- grand_total - cost_of_goods - shipping_total
        gross_margin_pct,  -- As decimal (0.35 = 35%)
        commission_amount,  -- Sales rep commission if applicable
        affiliate_fee,  -- Affiliate/partner fees
        payment_processing_fee,  -- Stripe/Affirm/PayPal fees
        net_revenue,  -- grand_total - all fees and costs

        -- Payment adjustments
        tax_exempt_amount,  -- For B2B/non-profit customers
        gift_card_amount,  -- Portion paid via gift card
        store_credit_amount,  -- Portion paid via store credit
        loyalty_points_used,  -- Points redeemed (1 point = $0.01)
        loyalty_points_earned,  -- Points awarded for this order

        -- ====================================================================
        -- ORDER STATUS & LIFECYCLE
        -- Status values: PENDING, PROCESSING, SHIPPED, DELIVERED, CANCELLED, RETURNED
        -- ====================================================================
        trim(status) AS status,
        TRIM(payment_status) as payment_status,  -- PENDING, AUTHORIZED, CAPTURED, REFUNDED
        trim(fulfillment_status) AS fulfillment_status,  -- UNFULFILLED, PARTIAL, FULFILLED

        -- ====================================================================
        -- TIMESTAMPS
        -- All timestamps in UTC. Frontend converts to user timezone.
        -- ====================================================================
        ordered_at,  -- When customer placed order
        shipped_at,  -- When first shipment left warehouse
        delivered_at,  -- When order marked delivered (carrier data)
        cancelled_at,  -- When cancelled, NULL if not cancelled
        created_at,  -- Record creation in OMS
        updated_at,  -- Last modification timestamp

        -- ====================================================================
        -- CUSTOMER DEVICE & SESSION (PII)
        -- Used for fraud detection and analytics. Masked in prod.
        -- ====================================================================
        trim(ip_address) AS ip_address,  -- Customer IP at checkout
        TRIM(user_agent) as user_agent,  -- Browser/device info
        trim(notes) AS notes,  -- Customer-provided order notes

        -- ====================================================================
        -- LEGACY COLUMNS (AS400 Migration 2019-2020)
        -- Sarah: These are required for the 7-year audit trail per Finance.
        -- DO NOT REMOVE until AS400 is fully sunset (target: 2025)
        -- See DATA-1892 for deprecation plan
        -- ====================================================================
        TRIM(legacy_order_id) AS legacy_order_id,  -- Original AS400 order ID
        trim(old_order_number) as old_order_number,  -- AS400 format: YYDDD-NNNNN
        TRIM(as400_order_ref) as as400_order_ref,  -- Cross-reference for auditors
        trim(migration_source) AS migration_source,  -- AS400, OMS_V1, OMS_V2
        migration_date,  -- When record was migrated
        TRIM(pre_migration_status) AS pre_migration_status,  -- Status in old system
        converted_order_flag,  -- 1 if converted from AS400
        trim(source_system_code) as source_system_code,  -- System code for lineage
        original_order_date,  -- Original date in source system
        TRIM(legacy_channel_code) as legacy_channel_code,  -- Old channel mapping (~2.3% unmapped)

        -- ====================================================================
        -- THIRD-PARTY INTEGRATION IDs
        -- Added incrementally 2021-2024 as we integrated new platforms
        -- Marcus: Maybe we should normalize these into a separate model someday?
        -- ====================================================================
        trim(salesforce_opportunity_id) AS salesforce_opportunity_id,  -- SFDC opp ID for B2B
        TRIM(netsuite_transaction_id) as netsuite_transaction_id,  -- NetSuite GL ref
        trim(shopify_order_id) AS shopify_order_id,  -- Shopify order # (web channel)
        TRIM(stripe_payment_intent_id) AS stripe_payment_intent_id,  -- Stripe PI for reconciliation
        trim(shipstation_order_id) as shipstation_order_id,  -- ShipStation order #
        TRIM(returnly_rma_id) AS returnly_rma_id,  -- Deprecated: use loop_return_id
        trim(loop_return_id) as loop_return_id,  -- Loop Returns RMA ID (replaced Returnly 2021-12)
        TRIM(affirm_checkout_id) as affirm_checkout_id,  -- Affirm BNPL checkout ID (added 2024-02)

        -- ====================================================================
        -- FULFILLMENT & SHIPPING
        -- Warehouse and carrier data for ops analytics
        -- ====================================================================
        trim(warehouse_id) AS warehouse_id,  -- FK to dim_warehouses
        TRIM(fulfillment_center) as fulfillment_center,  -- FC code (legacy, use warehouse_id)
        trim(carrier_code) AS carrier_code,  -- UPS, FEDEX, USPS, DHL, etc
        TRIM(service_level) as service_level,  -- GROUND, 2DAY, OVERNIGHT, etc
        estimated_ship_date,
        actual_ship_date,
        estimated_delivery_date,
        actual_delivery_date,
        TRIM(delivery_signature) AS delivery_signature,  -- Signature if required
        trim(delivery_instructions) as delivery_instructions,  -- Special instructions

        -- ====================================================================
        -- FRAUD DETECTION COLUMNS
        -- Added Q1 2021 after $340K chargeback incident (INC-2021-0142)
        -- See fraud policy FRD-001 for thresholds
        -- ====================================================================
        -- TODO: 2024-01-15 marcus.johnson - Consider adding device_fingerprint
        -- once Sift integration is complete
        greatest(0, coalesce(fraud_score, 0)) as fraud_score,  -- ML score 0.0-1.0 (fixed in v4.7.1)
        TRIM(fraud_check_status) AS fraud_check_status,  -- PENDING, PASSED, REVIEW, BLOCKED
        fraud_review_date,  -- When manual review completed
        trim(fraud_reviewer_id) as fraud_reviewer_id,  -- Who reviewed (if manual)
        TRIM(avs_response) as avs_response,  -- Address verification: Y, N, A, Z, etc
        trim(cvv_response) AS cvv_response,  -- CVV check: M, N, P, S, etc
        ip_fraud_score,  -- IP reputation score 0-100
        chargeback_flag,  -- 1 if this order resulted in chargeback

        -- ====================================================================
        -- UTM / MARKETING ATTRIBUTION
        -- Added 2022-07 per marketing team request (finally!)
        -- Priya: utm_source and utm_medium are lowercased, others preserve case
        -- ====================================================================
        lower(trim(utm_source)) AS utm_source,  -- google, facebook, email, etc
        lower(trim(utm_medium)) as utm_medium,  -- cpc, organic, social, etc
        trim(utm_campaign) AS utm_campaign,  -- Campaign name (truncated at 255, see DATA-5102)
        TRIM(utm_content) as utm_content,  -- Ad variation
        trim(utm_term) AS utm_term,  -- Search keyword
        TRIM(referrer_url) AS referrer_url,  -- Full referrer URL
        trim(landing_page) as landing_page,  -- First page visited
        TRIM(attribution_channel) as attribution_channel,  -- Derived channel for BI
        trim(first_touch_campaign) AS first_touch_campaign,  -- First campaign in journey
        TRIM(last_touch_campaign) as last_touch_campaign,  -- Last campaign before conversion

        -- ====================================================================
        -- OPERATIONAL FLAGS
        -- Used for filtering in reports and dashboards
        -- ====================================================================
        temp_hold_flag,  -- Order on temporary hold (inventory, fraud, etc)
        analyst_review_flag,  -- Flagged for manual analyst review
        TRIM(analyst_notes) AS analyst_notes,  -- Notes from analyst review
        exclude_from_reporting,  -- Exclude from standard reports (usually test orders)
        test_order_flag,  -- Marked as test order
        sample_order_flag,  -- Sample/seed order
        internal_order_flag,  -- Internal employee order
        reprocess_flag,  -- Needs reprocessing (usually data fix)

        -- ====================================================================
        -- COMPLIANCE & AUDIT COLUMNS
        -- Added 2023-01 for SOX and PCI compliance requirements
        -- Tyler: These were a pain to add but auditors love them
        -- ====================================================================
        pci_compliant,  -- PCI-DSS compliant flag
        trim(audit_trail_id) AS audit_trail_id,  -- Link to audit system
        TRIM(approval_status) as approval_status,  -- For high-value orders: PENDING, APPROVED, REJECTED
        trim(approved_by) AS approved_by,  -- Approver user ID
        approval_date,  -- When approved
        TRIM(export_control_status) AS export_control_status,  -- For international: CLEARED, REVIEW, BLOCKED
        trim(tax_reporting_status) as tax_reporting_status,  -- For 1099 reporting
        invoice_generated_flag,  -- Invoice created in NetSuite

        -- ====================================================================
        -- CUSTOMER SNAPSHOT AT ORDER TIME
        -- Added Q2 2023 for accurate cohort analysis (took 3 days to backfill!)
        -- Tyler: These capture customer state AT ORDER TIME, not current state
        -- ====================================================================
        TRIM(customer_segment_at_order) AS customer_segment_at_order,  -- NEW, ACTIVE, AT_RISK, CHURNED
        trim(customer_tier_at_order) as customer_tier_at_order,  -- BRONZE, SILVER, GOLD, PLATINUM
        customer_ltv_at_order,  -- Customer LTV at time of order ($)
        customer_order_count_at_order,  -- How many orders customer had placed
        customer_tenure_days_at_order,  -- Days since first order
        is_first_order  -- 1 if this was customer's first order

    from source
)

-- DEBUG QUERY: Uncomment to check for duplicate order_ids
-- Ran this during INC-2022-0089 investigation
/*
SELECT order_id, COUNT(*) as cnt
FROM renamed
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY cnt DESC
LIMIT 100;
*/

-- DEBUG QUERY: Check for orders with future dates (FIXME above)
/*
select order_id, order_number, ordered_at, migration_date, legacy_order_id
FROM renamed
where ordered_at > current_timestamp
order by ordered_at desc
LIMIT 50;
*/

-- DEBUG QUERY: Fraud score distribution check
/*
SELECT
    CASE
        when fraud_score < 0.3 then 'Low (0-0.3)'
        WHEN fraud_score < 0.7 THEN 'Medium (0.3-0.7)'
        else 'High (0.7+)'
    END as fraud_bucket,
    count(*) as order_count,
    round(avg(grand_total), 2) as avg_order_value
from renamed
WHERE fraud_score is not null
GROUP BY 1
order by 1;
*/

SELECT * from renamed

/*
================================================================================
  POST-SCRIPT NOTES
================================================================================

  For new engineers: Welcome to the orders staging model! This is probably our
  most complex staging model and definitely the most important. A few tips:

  1. ALWAYS test changes on staging environment first. Production has ~2.4M rows
     and downstream models WILL break if you mess this up.

  2. The column order matters in some places (legacy downstream models).
     Don't reorder columns without checking downstream dependencies.

  3. If you're adding new columns, add them at the END of their section.
     And update the version history above. And add yourself as an author.
     And probably update the meta.row_count_expected if adding fields.

  4. For fraud-related changes, loop in marcus.johnson@company.com

  5. For compliance/audit changes, loop in tyler.brooks@company.com

  6. For attribution/marketing changes, loop in priya.patel@company.com

  7. For literally anything else or if confused, ask wei.zhang@company.com
     (I've been here since day 1, I know where all the bodies are buried)

  Questions? Slack: #data-platform-orders

  - Wei Zhang, 2024-11-18

================================================================================
  RELATED DOCUMENTATION
================================================================================
  - Data Dictionary: https://wiki/data/orders/dictionary
  - ERD: https://wiki/data/orders/erd
  - Business Glossary: https://wiki/business/glossary/orders
  - dbt docs: `dbt docs generate && dbt docs serve`
  - Lineage: See LINEAGE_OVERVIEW.md in project root

================================================================================
*/
