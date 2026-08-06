# Web Session Quality Scoring

Build dbt models for web session quality analysis with engagement scoring and conversion probability.

## Your Task

Add dbt models to the existing dbt project that create web session quality metrics.

- DuckDB: `/app/dbt_models_duckdb/models/`
- Snowflake: `/app/dbt_models_snowflake/models/`

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
- Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank. A blank or omitted schema makes Snowflake silently default to `PUBLIC`, so your models get built in the wrong schema and the verifier cannot find them.

## Source

Use existing staging models: stg_digital__* in models/staging/digital/

## Required Models

### Intermediate Layer (`models/intermediate/digital/`)

#### int_session_engagement

One row per session_id from stg_digital__web_page_views and stg_digital__web_events.

| Column | Description |
|--------|-------------|
| session_id | Group key |
| total_pageviews | Total page views for this session |
| unique_pages_viewed | Number of distinct pages viewed |
| total_time_on_pages_seconds | Total time spent on pages, default 0 |
| avg_scroll_depth_percent | Average scroll depth across all page views, default 0 |
| product_page_views | Number of page views with page_type = 'PRODUCT' |
| category_page_views | Number of page views with page_type = 'CATEGORY' |
| cart_page_views | Number of page views with page_type = 'CART' |
| checkout_page_views | Number of page views with page_type = 'CHECKOUT' |
| add_to_cart_events | Number of events with event_type = 'ADD_TO_CART' |
| video_play_events | Number of events with event_type = 'VIDEO_PLAY' |
| search_events | Number of events with event_type = 'SEARCH' |

#### int_session_cart_activity

One row per session_id from stg_digital__shopping_carts.

| Column | Description |
|--------|-------------|
| session_id | Group key |
| cart_created | TRUE if session has a cart |
| cart_item_count | Maximum item count in cart, default 0 |
| cart_subtotal | Maximum cart subtotal, default 0 |
| cart_converted | TRUE if cart was converted |

#### int_session_product_interest

One row per session_id from stg_digital__web_page_views, stg_digital__shopping_cart_items, and stg_digital__wishlist_items.

| Column | Description |
|--------|-------------|
| session_id | Group key |
| unique_products_viewed | Count of distinct product_id from product page views |
| products_added_to_cart | Count of distinct variant_id added to cart in this session |
| products_wishlisted | Count of distinct variant_id added to wishlist in this session |
| cart_item_quantity | Total quantity of items added to cart, default 0 |
| avg_product_price | Average unit_price of items added to cart, default 0 |
| has_high_value_item | TRUE if any cart item unit_price > 100 |
| wishlist_to_cart_ratio | products_wishlisted divided by products_added_to_cart, default 0 if no cart items |
| product_interest_score | Weighted score: (unique_products_viewed x 2) + (products_added_to_cart x 5) + (products_wishlisted x 3), capped at 100, rounded to 2 decimals |

### Marts Layer (`models/marts/digital/`)

#### session_quality_scores

One row per session_id from stg_digital__web_sessions with int_session_engagement and int_session_cart_activity.

| Column | Description |
|--------|-------------|
| session_id | From stg_digital__web_sessions |
| visitor_id | From stg_digital__web_sessions |
| customer_id | From stg_digital__web_sessions, NULL if anonymous |
| session_start | From stg_digital__web_sessions |
| session_date | Date of session start |
| session_duration_seconds | From stg_digital__web_sessions.duration_seconds |
| session_duration_minutes | Duration in minutes, rounded to 2 decimals |
| page_views | From stg_digital__web_sessions.page_views |
| unique_pages_viewed | From int_session_engagement |
| landing_page | From stg_digital__web_sessions |
| device_type | From stg_digital__web_sessions |
| utm_source | From stg_digital__web_sessions, NULL if not available |
| utm_medium | From stg_digital__web_sessions, NULL if not available |
| utm_campaign | From stg_digital__web_sessions, NULL if not available |
| traffic_source | utm_source if available, otherwise 'direct' |
| product_views_count | From int_session_engagement.product_page_views |
| added_to_cart | TRUE if session has cart activity |
| cart_value | From int_session_cart_activity.cart_subtotal, default 0 |
| did_convert | TRUE if session or cart converted |
| engagement_score | Weighted engagement score (see below) |
| is_bounce | TRUE if single page view with duration under 10 seconds |
| bounce_type | 'IMMEDIATE' if bounce under 3 seconds, 'SHORT_VISIT' if bounce, NULL otherwise |
| conversion_probability | Predicted conversion probability (see below) |
| session_quality_tier | 'HIGH' if engagement_score >= 70, 'MEDIUM' if >= 40, 'LOW' otherwise |
| expected_value | conversion_probability multiplied by 150.0 |

#### visitor_product_affinity

One row per visitor_id from stg_digital__web_sessions with int_session_product_interest.

| Column | Description |
|--------|-------------|
| visitor_id | Group key |
| total_sessions | Count of sessions for this visitor |
| sessions_with_product_views | Count of sessions where unique_products_viewed > 0 |
| total_products_viewed | Sum of unique_products_viewed across all sessions |
| avg_products_per_session | total_products_viewed divided by total_sessions, rounded to 2 decimals |
| total_products_carted | Sum of products_added_to_cart across all sessions |
| total_products_wishlisted | Sum of products_wishlisted across all sessions |
| cart_conversion_rate | Sessions with cart divided by total_sessions, rounded to 2 decimals |
| wishlist_preference_score | total_products_wishlisted divided by (total_products_carted + total_products_wishlisted), default 0, rounded to 2 decimals |
| browse_to_action_ratio | total_products_viewed divided by (total_products_carted + total_products_wishlisted), default 0 if no actions, rounded to 2 decimals |
| high_value_shopper | TRUE if has_high_value_item in any session |
| visitor_segment | Categorize visitor behavior (see below) |
| first_session_date | Earliest session_start date |
| last_session_date | Latest session_start date |
| days_active | Days between first and last session, default 0 if single session |

## Engagement Score

Weighted composite score capped at 100:
- Page views: 5 points per page view (max 5 pages)
- Session duration: 1.5 points per minute (max 10 minutes)
- Product views: 10 points if any product views
- Added to cart: 15 points if cart created
- Checkout views: 5 points if any checkout page views
- Scroll depth: 10 points if average scroll >= 75%, otherwise score divided by 10
- Search events: 5 points if any searches
- Video events: 5 points if any video plays
- Unique pages: 10 points if 3+ unique pages, otherwise 3 points per unique page

Round to 2 decimals. Default 0 for NULL values.

## Conversion Probability

Score based on session behavior:
- Already converted: 1.0
- Visited checkout: 0.85
- High engagement (80+) with cart: 0.75
- Engagement score 70+: 0.65
- Engagement score 60+ with 3+ product views: 0.55
- Engagement score 50+: 0.45
- Engagement score 40+: 0.30
- Engagement score 30+ with product views: 0.25
- Engagement score 20+: 0.15
- Non-bounce sessions: 0.10
- Otherwise: 0.05

Round to 2 decimals.

## Visitor Segment

Categorize visitors based on behavior patterns:
- 'CONVERTER': cart_conversion_rate >= 0.5 (converts at least half their sessions)
- 'BROWSER': browse_to_action_ratio >= 5.0 AND cart_conversion_rate < 0.5 (high browsing, low conversion)
- 'RESEARCHER': wishlist_preference_score >= 0.6 (prefers wishlist over cart)
- 'CASUAL': Otherwise (doesn't fit other patterns)

## Requirements

### session_quality_scores
- Only include sessions from the last 90 days relative to the most recent session_start in the source data (do NOT use CURRENT_DATE)
- One row per session_id
- No NULL values in session_id, session_start, engagement_score, conversion_probability
- engagement_score range: 0-100
- conversion_probability range: 0.0-1.0
- Order by session_start descending

### visitor_product_affinity
- Only include visitors with sessions from the last 90 days relative to the most recent session_start in the source data (do NOT use CURRENT_DATE)
- One row per visitor_id
- No NULL values in visitor_id, total_sessions, first_session_date, last_session_date, visitor_segment
- cart_conversion_rate range: 0.0-1.0
- wishlist_preference_score range: 0.0-1.0
- browse_to_action_ratio range: 0.0 or higher
- visitor_segment must be one of: 'CONVERTER', 'BROWSER', 'RESEARCHER', 'CASUAL'
- Order by total_sessions descending, then by visitor_id

### int_session_product_interest
- One row per session_id
- No NULL values in session_id, product_interest_score
- product_interest_score range: 0-100

## Guidelines
- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
