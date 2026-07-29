-- Create marketing tables for campaign performance task
-- These tables don't exist in the base database, so we create them here

-- ============================================================
-- Table: stg_marketing__campaigns
-- ============================================================
CREATE TABLE IF NOT EXISTS main.stg_marketing__campaigns (
    campaign_id VARCHAR PRIMARY KEY,
    campaign_name VARCHAR,
    channel VARCHAR,
    start_date DATE,
    end_date DATE,
    budget DECIMAL(18,4),
    status VARCHAR,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert campaign data
INSERT INTO main.stg_marketing__campaigns (campaign_id, campaign_name, channel, start_date, end_date, budget, status) VALUES
('camp-001', 'Summer Sale 2025', 'EMAIL', '2025-06-01', '2025-06-30', 5000.00, 'COMPLETED'),
('camp-002', 'Back to School', 'EMAIL', '2025-08-01', '2025-08-31', 7500.00, 'COMPLETED'),
('camp-003', 'Black Friday Deals', 'EMAIL', '2025-11-20', '2025-11-30', 15000.00, 'COMPLETED'),
('camp-004', 'Holiday Gift Guide', 'EMAIL', '2025-12-01', '2025-12-24', 12000.00, 'COMPLETED'),
('camp-005', 'New Year Clearance', 'EMAIL', '2026-01-01', '2026-01-15', 8000.00, 'ACTIVE'),
('camp-006', 'Spring Collection Launch', 'EMAIL', '2025-03-15', '2025-04-15', 6000.00, 'COMPLETED'),
('camp-007', 'VIP Exclusive Offers', 'EMAIL', '2025-05-01', '2025-05-31', 3000.00, 'COMPLETED'),
('camp-008', 'Flash Sale Weekend', 'EMAIL', '2025-07-10', '2025-07-12', 2000.00, 'COMPLETED'),
('camp-009', 'Loyalty Rewards', 'EMAIL', '2025-09-01', '2025-09-30', 4500.00, 'COMPLETED'),
('camp-010', 'Product Launch - Electronics', 'EMAIL', '2025-10-15', '2025-10-31', 9000.00, 'COMPLETED'),
('camp-011', 'Winter Warmers', 'EMAIL', '2025-11-01', '2025-11-15', 5500.00, 'COMPLETED'),
('camp-012', 'Cyber Monday Special', 'EMAIL', '2025-12-01', '2025-12-02', 10000.00, 'COMPLETED');

-- ============================================================
-- Table: stg_marketing__email_events
-- ============================================================
CREATE TABLE IF NOT EXISTS main.stg_marketing__email_events (
    event_id VARCHAR PRIMARY KEY,
    customer_id VARCHAR,
    campaign_id VARCHAR,
    event_type VARCHAR,
    event_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Generate email events for each campaign
-- We'll create realistic funnel data: SENT > OPENED > CLICKED > CONVERTED

-- Get actual customer IDs from the database
CREATE TEMP TABLE temp_customers AS
SELECT customer_id, ROW_NUMBER() OVER (ORDER BY customer_id) as rn
FROM main.stg_customer__customers
WHERE status = 'ACTIVE'
LIMIT 500;

-- Campaign 001: Summer Sale - Good performance
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-001-' || rn || '-sent',
    customer_id,
    'camp-001',
    'SENT',
    TIMESTAMP '2025-06-01 10:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 200;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-001-' || rn || '-open',
    customer_id,
    'camp-001',
    'OPENED',
    TIMESTAMP '2025-06-01 12:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 120;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-001-' || rn || '-click',
    customer_id,
    'camp-001',
    'CLICKED',
    TIMESTAMP '2025-06-01 14:00:00' + (rn * INTERVAL '3 minute')
FROM temp_customers WHERE rn <= 60;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-001-' || rn || '-conv',
    customer_id,
    'camp-001',
    'CONVERTED',
    TIMESTAMP '2025-06-02 10:00:00' + (rn * INTERVAL '5 minute')
FROM temp_customers WHERE rn <= 25;

-- Campaign 002: Back to School - Medium performance
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-002-' || rn || '-sent',
    customer_id,
    'camp-002',
    'SENT',
    TIMESTAMP '2025-08-01 09:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 250;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-002-' || rn || '-open',
    customer_id,
    'camp-002',
    'OPENED',
    TIMESTAMP '2025-08-01 11:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 100;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-002-' || rn || '-click',
    customer_id,
    'camp-002',
    'CLICKED',
    TIMESTAMP '2025-08-01 13:00:00' + (rn * INTERVAL '3 minute')
FROM temp_customers WHERE rn <= 35;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-002-' || rn || '-conv',
    customer_id,
    'camp-002',
    'CONVERTED',
    TIMESTAMP '2025-08-02 10:00:00' + (rn * INTERVAL '5 minute')
FROM temp_customers WHERE rn <= 12;

-- Campaign 003: Black Friday - Excellent performance
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-003-' || rn || '-sent',
    customer_id,
    'camp-003',
    'SENT',
    TIMESTAMP '2025-11-20 08:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 400;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-003-' || rn || '-open',
    customer_id,
    'camp-003',
    'OPENED',
    TIMESTAMP '2025-11-20 10:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 300;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-003-' || rn || '-click',
    customer_id,
    'camp-003',
    'CLICKED',
    TIMESTAMP '2025-11-20 12:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 180;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-003-' || rn || '-conv',
    customer_id,
    'camp-003',
    'CONVERTED',
    TIMESTAMP '2025-11-21 10:00:00' + (rn * INTERVAL '3 minute')
FROM temp_customers WHERE rn <= 80;

-- Campaign 004: Holiday Gift Guide - Good performance
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-004-' || rn || '-sent',
    customer_id,
    'camp-004',
    'SENT',
    TIMESTAMP '2025-12-01 09:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn BETWEEN 50 AND 350;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-004-' || rn || '-open',
    customer_id,
    'camp-004',
    'OPENED',
    TIMESTAMP '2025-12-01 11:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn BETWEEN 50 AND 230;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-004-' || rn || '-click',
    customer_id,
    'camp-004',
    'CLICKED',
    TIMESTAMP '2025-12-01 14:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn BETWEEN 50 AND 130;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-004-' || rn || '-conv',
    customer_id,
    'camp-004',
    'CONVERTED',
    TIMESTAMP '2025-12-02 10:00:00' + (rn * INTERVAL '5 minute')
FROM temp_customers WHERE rn BETWEEN 50 AND 100;

-- Campaign 005: New Year Clearance - Active, lower performance
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-005-' || rn || '-sent',
    customer_id,
    'camp-005',
    'SENT',
    TIMESTAMP '2026-01-01 10:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 180;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-005-' || rn || '-open',
    customer_id,
    'camp-005',
    'OPENED',
    TIMESTAMP '2026-01-01 12:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 70;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-005-' || rn || '-click',
    customer_id,
    'camp-005',
    'CLICKED',
    TIMESTAMP '2026-01-01 15:00:00' + (rn * INTERVAL '3 minute')
FROM temp_customers WHERE rn <= 20;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-005-' || rn || '-conv',
    customer_id,
    'camp-005',
    'CONVERTED',
    TIMESTAMP '2026-01-02 10:00:00' + (rn * INTERVAL '5 minute')
FROM temp_customers WHERE rn <= 5;

-- Campaign 006: Spring Collection - Poor performance (ineffective tier)
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-006-' || rn || '-sent',
    customer_id,
    'camp-006',
    'SENT',
    TIMESTAMP '2025-03-15 10:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn BETWEEN 100 AND 250;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-006-' || rn || '-open',
    customer_id,
    'camp-006',
    'OPENED',
    TIMESTAMP '2025-03-15 14:00:00' + (rn * INTERVAL '3 minute')
FROM temp_customers WHERE rn BETWEEN 100 AND 130;

-- No clicks or conversions for this campaign (ineffective)

-- Campaign 007: VIP Exclusive - High click rate, good conversions
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-007-' || rn || '-sent',
    customer_id,
    'camp-007',
    'SENT',
    TIMESTAMP '2025-05-01 09:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 80;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-007-' || rn || '-open',
    customer_id,
    'camp-007',
    'OPENED',
    TIMESTAMP '2025-05-01 11:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 65;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-007-' || rn || '-click',
    customer_id,
    'camp-007',
    'CLICKED',
    TIMESTAMP '2025-05-01 13:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 50;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-007-' || rn || '-conv',
    customer_id,
    'camp-007',
    'CONVERTED',
    TIMESTAMP '2025-05-02 10:00:00' + (rn * INTERVAL '5 minute')
FROM temp_customers WHERE rn <= 30;

-- Campaign 008: Flash Sale - Very high conversion rate (top performer)
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-008-' || rn || '-sent',
    customer_id,
    'camp-008',
    'SENT',
    TIMESTAMP '2025-07-10 08:00:00' + (rn * INTERVAL '30 second')
FROM temp_customers WHERE rn <= 100;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-008-' || rn || '-open',
    customer_id,
    'camp-008',
    'OPENED',
    TIMESTAMP '2025-07-10 09:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 85;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-008-' || rn || '-click',
    customer_id,
    'camp-008',
    'CLICKED',
    TIMESTAMP '2025-07-10 10:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 70;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-008-' || rn || '-conv',
    customer_id,
    'camp-008',
    'CONVERTED',
    TIMESTAMP '2025-07-10 12:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 45;

-- Campaign 009: Loyalty Rewards - Moderate performance
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-009-' || rn || '-sent',
    customer_id,
    'camp-009',
    'SENT',
    TIMESTAMP '2025-09-01 10:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn BETWEEN 200 AND 400;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-009-' || rn || '-open',
    customer_id,
    'camp-009',
    'OPENED',
    TIMESTAMP '2025-09-01 12:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn BETWEEN 200 AND 320;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-009-' || rn || '-click',
    customer_id,
    'camp-009',
    'CLICKED',
    TIMESTAMP '2025-09-01 15:00:00' + (rn * INTERVAL '3 minute')
FROM temp_customers WHERE rn BETWEEN 200 AND 260;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-009-' || rn || '-conv',
    customer_id,
    'camp-009',
    'CONVERTED',
    TIMESTAMP '2025-09-02 10:00:00' + (rn * INTERVAL '5 minute')
FROM temp_customers WHERE rn BETWEEN 200 AND 225;

-- Campaign 010: Product Launch - Low clicks (underperforming)
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-010-' || rn || '-sent',
    customer_id,
    'camp-010',
    'SENT',
    TIMESTAMP '2025-10-15 09:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 300;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-010-' || rn || '-open',
    customer_id,
    'camp-010',
    'OPENED',
    TIMESTAMP '2025-10-15 11:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 90;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-010-' || rn || '-click',
    customer_id,
    'camp-010',
    'CLICKED',
    TIMESTAMP '2025-10-15 14:00:00' + (rn * INTERVAL '3 minute')
FROM temp_customers WHERE rn <= 15;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-010-' || rn || '-conv',
    customer_id,
    'camp-010',
    'CONVERTED',
    TIMESTAMP '2025-10-16 10:00:00' + (rn * INTERVAL '5 minute')
FROM temp_customers WHERE rn <= 8;

-- Campaign 011: Winter Warmers - Average performance
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-011-' || rn || '-sent',
    customer_id,
    'camp-011',
    'SENT',
    TIMESTAMP '2025-11-01 10:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn BETWEEN 150 AND 350;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-011-' || rn || '-open',
    customer_id,
    'camp-011',
    'OPENED',
    TIMESTAMP '2025-11-01 12:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn BETWEEN 150 AND 280;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-011-' || rn || '-click',
    customer_id,
    'camp-011',
    'CLICKED',
    TIMESTAMP '2025-11-01 14:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn BETWEEN 150 AND 210;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-011-' || rn || '-conv',
    customer_id,
    'camp-011',
    'CONVERTED',
    TIMESTAMP '2025-11-02 10:00:00' + (rn * INTERVAL '5 minute')
FROM temp_customers WHERE rn BETWEEN 150 AND 180;

-- Campaign 012: Cyber Monday - High volume, good conversion
INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-012-' || rn || '-sent',
    customer_id,
    'camp-012',
    'SENT',
    TIMESTAMP '2025-12-01 06:00:00' + (rn * INTERVAL '30 second')
FROM temp_customers WHERE rn <= 450;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-012-' || rn || '-open',
    customer_id,
    'camp-012',
    'OPENED',
    TIMESTAMP '2025-12-01 08:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 320;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-012-' || rn || '-click',
    customer_id,
    'camp-012',
    'CLICKED',
    TIMESTAMP '2025-12-01 10:00:00' + (rn * INTERVAL '1 minute')
FROM temp_customers WHERE rn <= 200;

INSERT INTO main.stg_marketing__email_events (event_id, customer_id, campaign_id, event_type, event_at)
SELECT
    'evt-012-' || rn || '-conv',
    customer_id,
    'camp-012',
    'CONVERTED',
    TIMESTAMP '2025-12-01 14:00:00' + (rn * INTERVAL '2 minute')
FROM temp_customers WHERE rn <= 90;

-- Clean up temp table
DROP TABLE temp_customers;

-- Verify data
SELECT 'stg_marketing__campaigns' as table_name, COUNT(*) as row_count FROM main.stg_marketing__campaigns
UNION ALL
SELECT 'stg_marketing__email_events' as table_name, COUNT(*) as row_count FROM main.stg_marketing__email_events;
