# Cart Recovery Prioritization — Agent Instructions (Natural Language)

## Objective
Create a dbt model set that prioritizes abandoned carts for recovery outreach.

## Naming and References
- Use `ref('stg_*')` 
- The upstream limit counts only distinct `ref()` calls to the allowed staging models below. References to your own intermediate models do **not** count toward the 10.

## Critical Constraint
- **Use `ref()` to reference models. Do NOT use `source()`** anywhere in these models.

## Required Outputs
Produce a final mart model that outputs a prioritized recovery queue with recovery windows, recommended channel, and incentive flag. Supporting intermediate models should compute cart base, session signals, inventory risk, and customer/consent context.

## Output Schema and Exact Model Names
Create **exactly** the following dbt models (names are case-sensitive):
- `int_cart_recovery__cart_base`
- `int_cart_recovery__session_signals`
- `int_cart_recovery__inventory_risk`
- `int_cart_recovery__customer_context`
- `fct_cart_recovery_priority`

### Final Mart Schema (`fct_cart_recovery_priority`)
The final mart must include **all** of the columns below (order not enforced):
- cart_id, customer_id, session_id, channel_id
- cart_status, cart_merch_value
- item_line_count, distinct_variants, total_quantity
- last_activity_at, hours_since_last_activity, cart_age_hours
- device_type, utm_source, utm_medium, utm_campaign
- checkout_event_count, payment_error_count, add_to_cart_count, remove_from_cart_count
- inventory_risk_level
- tier_name, tier_level, total_lifetime_value, total_orders, churn_risk_score, propensity_to_buy, customer_segment_snapshot
- recommended_channel, priority_score, priority_tier
- recovery_window_hours, recovery_window_start, recovery_window_end
- incentive_flag
- recovered_order_id, recovered_at, recovered_grand_total, is_recovered
- scored_at

### Intermediate Schemas
Each intermediate model must include **all** of the columns below (order not enforced).

#### `int_cart_recovery__cart_base`
- cart_id, session_id, customer_id, channel_id
- cart_status, cart_item_count_reported, cart_subtotal_reported
- created_at, updated_at, converted_at, order_id
- abandoned_status, abandoned_loaded_at
- item_line_count, distinct_variants, total_quantity, items_total
- first_item_added_at, last_item_added_at, last_item_updated_at
- cart_merch_value, last_activity_at
- is_converted, is_abandoned
- hours_since_last_activity, cart_age_hours

#### `int_cart_recovery__session_signals`
- session_id, visitor_id, customer_id, channel_id
- session_start, session_end, duration_seconds, page_views
- landing_page, exit_page, referrer
- utm_source, utm_medium, utm_campaign
- device_type, browser, os, ip_address, country
- is_converted
- event_count, checkout_event_count, payment_error_count
- add_to_cart_count, remove_from_cart_count, product_view_count
- first_event_at, last_event_at
- checkout_depth_score, cart_add_net, checkout_event_ratio

#### `int_cart_recovery__inventory_risk`
- cart_id
- cart_line_count, total_qty
- line_out_of_stock, line_low_stock_status
- min_quantity_available, total_quantity_available
- inventory_risk_flag, inventory_risk_level

#### `int_cart_recovery__customer_context`
- customer_id, customer_type, email, phone_primary
- total_lifetime_value, total_orders, current_tier_id
- churn_risk_score, propensity_to_buy
- days_since_last_order, customer_tenure_days
- preferred_language, preferred_currency
- customer_segment_snapshot
- tier_name, tier_level, discount_percentage, free_shipping
- email_consent, sms_consent, push_consent, personalization_consent
- last_consent_at

## Where to Place Models
- Create intermediate models under an appropriate `models/intermediate/` subfolder (e.g., `cart_recovery/`).
- Create the final mart under `models/marts/digital/`.

## Allowed Upstream Models
Use only models with the `stg_` prefix. Recommended:
1. `stg_shopping_carts`
2. `stg_shopping_cart_items`
3. `stg_abandoned_carts_stg`
4. `stg_web_sessions`
5. `stg_web_events`
6. `stg_inventory_levels`
7. `stg_customer__customers`
8. `stg_customer__customer_tiers`
9. `stg_consent_preferences`
10. `stg_orders__orders`

## Staging Model Schemas (Required Columns)
These columns are guaranteed to exist and should be used in your SQL.

### `stg_shopping_carts`
- cart_id, session_id, customer_id, channel_id
- status, item_count, subtotal
- created_at, updated_at, converted_at, order_id

### `stg_shopping_cart_items`
- cart_id, variant_id
- quantity, line_total
- added_at, updated_at

### `stg_abandoned_carts_stg`
- _id (cart id), _status, _loaded_at

### `stg_web_sessions`
- session_id, visitor_id, customer_id, channel_id
- session_start, session_end, duration_seconds, page_views
- landing_page, exit_page, referrer
- utm_source, utm_medium, utm_campaign
- device_type, browser, os, ip_address, country, is_converted

### `stg_web_events`
- session_id, event_name, event_type, event_timestamp

### `stg_inventory_levels`
- variant_id, quantity_available, quantity_reserved, quantity_on_hand
- inventory_status

### `stg_customer__customers`
- customer_id, customer_type, email, phone_primary
- total_lifetime_value, total_orders, current_tier_id
- churn_risk_score, propensity_to_buy
- days_since_last_order, customer_tenure_days
- preferred_language, preferred_currency
- customer_segment_snapshot

### `stg_customer__customer_tiers`
- tier_id, tier_name, tier_level
- discount_percentage, free_shipping

### `stg_consent_preferences`
- customer_id, consent_type, is_consented, consent_date

### `stg_orders__orders`
- order_id, customer_id, ordered_at, status, grand_total

## Enumerations and Filters
- **Consent types** to map (case-insensitive):
  - EMAIL: `MARKETING_EMAIL`, `EMAIL`
  - SMS: `MARKETING_SMS`, `SMS`
  - PUSH: `MARKETING_PUSH`, `PUSH`, `PUSH_NOTIFICATIONS`
  - PERSONALIZATION: `PERSONALIZATION`, `ANALYTICS`
- **Order statuses to exclude** from recovery matching (case-insensitive):
  - `CANCELLED`, `VOID`, `TEST`

## Deterministic Time Handling (No `current_timestamp`)
- To avoid non-deterministic outputs, **do not** use `current_timestamp` directly.
- Use hard coded value `'2026-01-22T12:00:00.000'` for `as_of_timestamp`
- Use this `as_of_timestamp` for:
  - `hours_since_last_activity`
  - `cart_age_hours`
  - `scored_at`

---

## Business Rules (Natural Language)

### 1) Cart Base & Abandonment
- Treat a cart as **converted** if it has:
  - a non‑null `order_id`, OR
  - a non‑null `converted_at`, OR
  - a `status` of "CONVERTED" (case‑insensitive).
- Treat a cart as **abandoned** if:
  - `status` is "ABANDONED" (case‑insensitive), OR
  - it appears in `stg_abandoned_carts_stg` **with `_status` = "ABANDONED"** (case‑insensitive), OR
  - it is **not converted** and has a status in {CANCELLED, EXPIRED}.
- Compute cart value as **items total if available**, otherwise **cart subtotal**, otherwise **0**.
- Define **last activity timestamp** as the latest of cart updated time, last cart item update, or cart converted time (if any).
- Compute **hours since last activity** and **cart age (hours)** relative to the deterministic `as_of_timestamp` (see Deterministic Time Handling).

### 2) Item Rollups
For each cart:
- Count line items, distinct variants, total quantity, item totals.
- Track first and last item add/update time.

### 3) Session Intent & Friction Signals (Exact SQL Logic)
For each session:
- Use `select *` from `stg_web_sessions` and `stg_web_events`.
- Aggregate events per session using conditional counts (use `sum(case when ... then 1 else 0 end)` or Jinja conditionals for cross-DB compatibility):
  - `event_count = count(*)`
  - `checkout_event_count` = count of events where `lower(event_name) like '%checkout%' or lower(event_type) like '%checkout%'`
  - `payment_error_count` = count of events where `lower(event_name) like '%payment%' and lower(event_type) = 'error'`
  - `add_to_cart_count` = count of events where `lower(event_name) like '%add%' and lower(event_name) like '%cart%'`
  - `remove_from_cart_count` = count of events where `lower(event_name) like '%remove%' and lower(event_name) like '%cart%'`
  - `product_view_count` = count of events where `lower(event_name) like '%view%' and lower(event_name) like '%product%'`
  - `first_event_at = min(event_timestamp)` / `last_event_at = max(event_timestamp)`
- Left join the event aggregates to sessions on `session_id`.
- Do **not** coalesce event counts in the final select; allow NULL when a session has no events.
- Define **checkout depth score** using coalesce on counts:
  - 2 if `payment_error_count > 0`
  - 1 if `checkout_event_count > 0`
  - 0 otherwise
- Calculate **checkout event ratio** as `coalesce(checkout_event_count, 0)::numeric / nullif(event_count, 0)` (so 0/NULL yields NULL).
- Model config: `materialized='view'`, tags `['intermediate','cart_recovery','digital']`.

### 4) Inventory Risk (Exact SQL Logic)
For each cart:
- Join `stg_shopping_cart_items` to `stg_inventory_levels` on `variant_id`.
- Build item-level fields:
  - Use `quantity` from cart items (rollups should use `coalesce(quantity, 0)`).
  - Use `quantity_available` from inventory (rollups should use `coalesce(quantity_available, 0)` for sums).
  - `line_out_of_stock` (per line): `case when coalesce(quantity_available, 0) < coalesce(quantity, 0) then 1 else 0 end`.
    - Do **not** use `inventory_status` for out-of-stock logic.
  - `line_low_stock_status` (per line): `case when upper(coalesce(inventory_status, '')) in ('LOW_STOCK', 'OUT_OF_STOCK') then 1 else 0 end`.
- Roll up per cart:
  - `cart_line_count = count(*)`
  - `total_qty = sum(coalesce(quantity, 0))`
  - `line_out_of_stock = sum(line_out_of_stock)`
  - `line_low_stock_status = sum(line_low_stock_status)`
  - `min_quantity_available = min(quantity_available)`
  - `total_quantity_available = sum(coalesce(quantity_available, 0))`
- Risk flags:
  - `inventory_risk_flag = (line_out_of_stock > 0 OR line_low_stock_status > 0)`
  - `inventory_risk_level = 'OUT_OF_STOCK' if line_out_of_stock > 0; else 'LOW_STOCK' if line_low_stock_status > 0; else 'OK'`.
- Model config: `materialized='view'`, tags `['intermediate','cart_recovery','inventory']`.

### 5) Customer & Consent Context
- Attach tier, LTV, total orders, churn risk, propensity, and segment snapshot from customer/tier tables.
- Pivot consent preferences to flags for **email**, **sms**, **push**, and **personalization**.
- If consent missing, treat as not consented.
  - Use the consent type mapping in "Enumerations and Filters".
- Consent flags must be integer 1/0 (not boolean), using `max(case ... then 1 else 0 end)` and `coalesce(..., 0)`.

### 6) Recovery Match (Suppression)
- If an order exists for the same customer **within 7 days after cart last activity**, treat cart as **recovered**.
- Exclude orders with status in `CANCELLED`, `VOID`, `TEST` (case-insensitive).
- Apply the status filter in the join condition using `upper(coalesce(status, '')) not in (...)` so NULL statuses are retained.
- Use the **earliest** matching order per cart (e.g., `min(ordered_at)` / `min(order_id)` / `min(grand_total)` grouped by cart_id).
- Exclude recovered carts from prioritization, or mark as recovered in final output.

### 7) Priority Score
Compute a weighted score using the following explicit weights:
- **Value score** (based on `cart_merch_value`):
  - >= 500 => 30 points
  - 200–499.99 => 22 points
  - 100–199.99 => 15 points
  - < 100 => 8 points
- **Intent score** (based on `checkout_depth_score`):
  - depth = 2 => 20 points
  - depth = 1 => 12 points
  - depth = 0 => 5 points
- **Customer score** (based on `tier_level`, treat null as 0):
  - tier_level >= 4 => 15 points
  - tier_level >= 3 => 10 points
  - tier_level >= 2 => 6 points
  - otherwise => 3 points
- **Friction adjustment**:
  - payment_error_count > 0 => -5 points
  - else if remove_from_cart_count > 0 => -2 points
  - else => 0 points
- **Inventory adjustment**:
  - inventory_risk_flag = true => -5 points
  - else => 0 points

### 8) Priority Tier
- P0 if priority_score >= 55
- P1 if priority_score >= 40 and < 55
- P2 if priority_score < 40

### 9) Recommended Channel
- Choose first available consented channel in priority order:
  1. Email
  2. SMS
  3. Push
- If none consented, set to **SUPPRESS**.

### 10) Recovery Window
- Assign recovery window hours by priority:
  - P0: 2 hours
  - P1: 24 hours
  - P2: 72 hours

### 11) Incentive Flag
- Recommend incentive only for high‑priority carts with friction (payment error) or inventory risk.
- Do not auto‑discount low‑priority carts.
- Explicit logic:
  - if priority_score >= 55 and (payment_error_count > 0 OR inventory_risk_flag) then true
  - else if priority_score >= 40 and payment_error_count > 0 then true
  - else false

---

## Final Output Columns (Minimum Set)
Include at least:
- cart_id, customer_id, session_id, channel_id
- cart value, item counts, last activity timestamp
- priority_score, priority_tier
- recommended_channel
- recovery_window_start, recovery_window_end
- incentive_flag
- recovered_order_id / recovered_at / is_recovered

---

## Implementation Notes
- Use **ref()** for every upstream model and for intermediate models.
- Keep all logic inside dbt models, not macros.
- Ensure the final mart only filters on `is_abandoned = true` (do **not** also filter `is_converted = false`).
- Do **not** coalesce `inventory_risk_level` in the final model; keep it as provided by the inventory risk join.
- Set `is_recovered` to `recovered_order_id is not null OR is_converted`.
- Final model should be `materialized='table'` with tags `['marts','digital','cart_recovery']`.
- Intermediate models should be `materialized='view'` and tagged appropriately (see gold standard).

## Database Backend
This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)

### Snowflake
- Set `DB_TYPE=snowflake`
- Environment variables (pre-configured):
  - `SNOWFLAKE_ACCOUNT`
  - `SNOWFLAKE_USER`
  - `SNOWFLAKE_PASSWORD`
  - `SNOWFLAKE_DATABASE` - The clone database to use
  - `SNOWFLAKE_SCHEMA`
  - `SNOWFLAKE_WAREHOUSE`
  - `SNOWFLAKE_ROLE` (optional)

**Note**: For Snowflake, the entrypoint automatically creates a clone database and sets `SNOWFLAKE_DATABASE`. The clone is destroyed when the task completes.

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Files
- DuckDB: `/app/dbt_models_duckdb/models/intermediate/cart_recovery/` and `/app/dbt_models_duckdb/models/marts/digital/`
- Snowflake: `/app/dbt_models_snowflake/models/intermediate/cart_recovery/` and `/app/dbt_models_snowflake/models/marts/digital/`

## Guidelines
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
