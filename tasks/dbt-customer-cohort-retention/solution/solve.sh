#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

# Set dbt project directory based on database type
if [ "$DB_TYPE" = "snowflake" ]; then
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_SNOWFLAKE:-/app/dbt_models_snowflake}"
    echo "Using Snowflake clone database: ${SNOWFLAKE_DATABASE:-not set}"
else
    DBT_PROJECT_DIR="${DBT_PROJECT_DIR_DUCKDB:-/app/dbt_models_duckdb}"
fi

echo "Using dbt project: $DBT_PROJECT_DIR"

# Create profiles.yml based on database type
echo "Setting up dbt profiles..."

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    # Snowflake profile - uses private key authentication
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: ${SNOWFLAKE_SCHEMA}
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE (using private key auth)"
else
    # DuckDB profile (default)
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > "$DBT_PROJECT_DIR/profiles.yml" <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      threads: 4
PROFILES
    echo "Configured DuckDB profile with path: $DUCKDB_PATH"
fi

cd "$DBT_PROJECT_DIR"
export DBT_PROFILES_DIR="$DBT_PROJECT_DIR"

# Install dbt dependencies
dbt deps

# Create staging directory for cohort models
mkdir -p models/staging/cohort
mkdir -p models/intermediate/cohort
mkdir -p models/marts/cohort

if [ "$DB_TYPE" = "snowflake" ]; then
    # ============================================================
    # SNOWFLAKE: Do NOT create _sources.yml -- the base Snowflake project
    # already defines source 'orders' (schema ORDERS) and source 'customer'
    # (schema CUSTOMER). Reference those directly.
    # ============================================================

    # Create staging model for orders (Snowflake)
    cat > models/staging/cohort/stg_cohort__orders.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    ordered_at,
    grand_total,
    trim(status) as status
from {{ source('orders', 'ORDERS') }}
where ordered_at >= '2023-01-01'
  and ordered_at < '2025-01-01'
EOF

    # Create staging model for customers (Snowflake)
    cat > models/staging/cohort/stg_cohort__customers.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(customer_id) as customer_id,
    trim(customer_number) as customer_number,
    trim(first_name) as first_name,
    trim(last_name) as last_name
from {{ source('customer', 'CUSTOMERS') }}
EOF

else
    # ============================================================
    # DUCKDB: Create sources.yml and staging models from scratch
    # ============================================================

    # Create sources.yml
    cat > models/staging/cohort/_sources.yml << 'EOF'
version: 2

sources:
  - name: main
    schema: main
    tables:
      - name: orders
      - name: customers
EOF

    # Create staging model for orders (DuckDB)
    cat > models/staging/cohort/stg_cohort__orders.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    ordered_at,
    grand_total,
    trim(status) as status
from {{ source('main', 'orders') }}
where ordered_at >= '2023-01-01'
  and ordered_at < '2025-01-01'
EOF

    # Create staging model for customers (DuckDB)
    cat > models/staging/cohort/stg_cohort__customers.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(customer_id) as customer_id,
    trim(customer_number) as customer_number,
    trim(first_name) as first_name,
    trim(last_name) as last_name
from {{ source('main', 'customers') }}
EOF

fi

# Create intermediate model for customer cohorts
cat > models/intermediate/cohort/int_cohort__customer_cohorts.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

/*
    Identify customer cohorts based on their first order date.
    Only include valid orders (not cancelled or returned).
*/

with valid_orders as (
    select
        customer_id,
        ordered_at,
        grand_total
    from {{ ref('stg_cohort__orders') }}
    where status not in ('CANCELLED', 'RETURNED')
),

customer_first_order as (
    select
        customer_id,
        min(ordered_at) as first_order_date,
        {% if target.type == 'duckdb' %}
        strftime('%Y-%m', min(ordered_at)) as cohort_month
        {% else %}
        TO_CHAR(min(ordered_at), 'YYYY-MM') as cohort_month
        {% endif %}
    from valid_orders
    group by customer_id
)

select * from customer_first_order
EOF

# Create cohort_retention mart model with cumulative metrics
cat > models/marts/cohort/cohort_retention.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Monthly cohort retention analysis.
    Tracks how many customers from each cohort make purchases in subsequent months.
    Includes cumulative retention metrics.
*/

with valid_orders as (
    select
        customer_id,
        ordered_at,
        grand_total
    from {{ ref('stg_cohort__orders') }}
    where status not in ('CANCELLED', 'RETURNED')
),

customer_cohorts as (
    select * from {{ ref('int_cohort__customer_cohorts') }}
),

-- Calculate cohort sizes
cohort_sizes as (
    select
        cohort_month,
        count(distinct customer_id) as cohort_size
    from customer_cohorts
    group by cohort_month
),

-- Calculate months since first order for each order
order_months as (
    select
        vo.customer_id,
        cc.cohort_month,
        cc.first_order_date,
        cast(
            (extract(year from vo.ordered_at) - extract(year from cc.first_order_date)) * 12 +
            (extract(month from vo.ordered_at) - extract(month from cc.first_order_date))
            as integer
        ) as months_since_first_order
    from valid_orders vo
    inner join customer_cohorts cc on vo.customer_id = cc.customer_id
),

-- Get minimum months_since_first_order per customer per cohort (for cumulative counting)
customer_first_month as (
    select
        customer_id,
        cohort_month,
        min(months_since_first_order) as first_active_month
    from order_months
    group by customer_id, cohort_month
),

-- Count retained customers per cohort-month combination
retention_data as (
    select
        cohort_month,
        months_since_first_order,
        count(distinct customer_id) as retained_customers
    from order_months
    group by cohort_month, months_since_first_order
),

-- Calculate cumulative retained: count distinct customers who had any activity up to each month
-- A customer is counted in cumulative_retained for month M if they had ANY purchase in months 0..M
cumulative_retention as (
    select
        rd.cohort_month,
        rd.months_since_first_order,
        count(distinct cfm.customer_id) as cumulative_retained
    from retention_data rd
    inner join customer_first_month cfm
        on rd.cohort_month = cfm.cohort_month
        and cfm.first_active_month <= rd.months_since_first_order
    group by rd.cohort_month, rd.months_since_first_order
),

-- Join with cohort sizes and calculate retention rates
final as (
    select
        rd.cohort_month,
        rd.months_since_first_order,
        cs.cohort_size,
        rd.retained_customers,
        round(rd.retained_customers * 100.0 / cs.cohort_size, 2) as retention_rate,
        cr.cumulative_retained,
        round(cr.cumulative_retained * 100.0 / cs.cohort_size, 2) as cumulative_retention_rate
    from retention_data rd
    inner join cohort_sizes cs on rd.cohort_month = cs.cohort_month
    inner join cumulative_retention cr on rd.cohort_month = cr.cohort_month
        and rd.months_since_first_order = cr.months_since_first_order
)

select * from final
order by cohort_month, months_since_first_order
EOF

# Create cohort_revenue mart model with cumulative metrics
cat > models/marts/cohort/cohort_revenue.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Revenue analysis by cohort.
    Tracks total revenue and revenue per customer for each cohort-month combination.
    Includes cumulative revenue metrics.
*/

with valid_orders as (
    select
        customer_id,
        ordered_at,
        grand_total
    from {{ ref('stg_cohort__orders') }}
    where status not in ('CANCELLED', 'RETURNED')
),

customer_cohorts as (
    select * from {{ ref('int_cohort__customer_cohorts') }}
),

-- Calculate cohort sizes
cohort_sizes as (
    select
        cohort_month,
        count(distinct customer_id) as cohort_size
    from customer_cohorts
    group by cohort_month
),

-- Calculate revenue per cohort-month
order_revenue as (
    select
        cc.cohort_month,
        cast(
            (extract(year from vo.ordered_at) - extract(year from cc.first_order_date)) * 12 +
            (extract(month from vo.ordered_at) - extract(month from cc.first_order_date))
            as integer
        ) as months_since_first_order,
        vo.grand_total
    from valid_orders vo
    inner join customer_cohorts cc on vo.customer_id = cc.customer_id
),

-- Aggregate revenue per cohort-month
revenue_data as (
    select
        cohort_month,
        months_since_first_order,
        round(sum(grand_total), 2) as total_revenue
    from order_revenue
    group by cohort_month, months_since_first_order
),

-- Calculate cumulative revenue using window function
revenue_with_cumulative as (
    select
        cohort_month,
        months_since_first_order,
        total_revenue,
        round(sum(total_revenue) over (
            partition by cohort_month
            order by months_since_first_order
            rows between unbounded preceding and current row
        ), 2) as cumulative_revenue
    from revenue_data
),

-- Join with cohort sizes and calculate per customer metrics
final as (
    select
        rwc.cohort_month,
        rwc.months_since_first_order,
        cs.cohort_size,
        rwc.total_revenue,
        round(rwc.total_revenue / cs.cohort_size, 2) as revenue_per_customer,
        rwc.cumulative_revenue,
        round(rwc.cumulative_revenue / cs.cohort_size, 2) as cumulative_revenue_per_customer
    from revenue_with_cumulative rwc
    inner join cohort_sizes cs on rwc.cohort_month = cs.cohort_month
)

select * from final
order by cohort_month, months_since_first_order
EOF

# Create cohort_summary mart model
cat > models/marts/cohort/cohort_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
    Summary metrics for each cohort.
    One row per cohort with aggregate lifetime metrics.
*/

with valid_orders as (
    select
        customer_id,
        ordered_at,
        grand_total,
        order_id
    from {{ ref('stg_cohort__orders') }}
    where status not in ('CANCELLED', 'RETURNED')
),

customer_cohorts as (
    select * from {{ ref('int_cohort__customer_cohorts') }}
),

-- Get retention data for month 6 and 12 lookups
retention_data as (
    select * from {{ ref('cohort_retention') }}
),

-- Calculate cohort sizes
cohort_sizes as (
    select
        cohort_month,
        count(distinct customer_id) as cohort_size
    from customer_cohorts
    group by cohort_month
),

-- Calculate total lifetime revenue per cohort
cohort_revenue as (
    select
        cc.cohort_month,
        round(sum(vo.grand_total), 2) as total_lifetime_revenue,
        count(distinct vo.order_id) as total_orders
    from valid_orders vo
    inner join customer_cohorts cc on vo.customer_id = cc.customer_id
    group by cc.cohort_month
),

-- Calculate orders per customer
orders_per_customer as (
    select
        cc.cohort_month,
        cc.customer_id,
        count(distinct vo.order_id) as order_count
    from customer_cohorts cc
    inner join valid_orders vo on cc.customer_id = vo.customer_id
    group by cc.cohort_month, cc.customer_id
),

avg_orders as (
    select
        cohort_month,
        round(avg(order_count), 2) as avg_orders_per_customer
    from orders_per_customer
    group by cohort_month
),

-- Calculate months active (distinct months with purchases)
months_active as (
    select
        cc.cohort_month,
        count(distinct
            {% if target.type == 'duckdb' %}
            strftime('%Y-%m', vo.ordered_at)
            {% else %}
            TO_CHAR(vo.ordered_at, 'YYYY-MM')
            {% endif %}
        ) as months_active
    from valid_orders vo
    inner join customer_cohorts cc on vo.customer_id = cc.customer_id
    group by cc.cohort_month
),

-- Get retention at month 6
retention_month_6 as (
    select
        cohort_month,
        retention_rate as retention_month_6
    from retention_data
    where months_since_first_order = 6
),

-- Get retention at month 12
retention_month_12 as (
    select
        cohort_month,
        retention_rate as retention_month_12
    from retention_data
    where months_since_first_order = 12
),

-- Combine all metrics
final as (
    select
        cs.cohort_month,
        cs.cohort_size,
        cr.total_lifetime_revenue,
        round(cr.total_lifetime_revenue / cs.cohort_size, 2) as avg_revenue_per_customer,
        ao.avg_orders_per_customer,
        ma.months_active,
        rm6.retention_month_6,
        rm12.retention_month_12
    from cohort_sizes cs
    inner join cohort_revenue cr on cs.cohort_month = cr.cohort_month
    inner join avg_orders ao on cs.cohort_month = ao.cohort_month
    inner join months_active ma on cs.cohort_month = ma.cohort_month
    left join retention_month_6 rm6 on cs.cohort_month = rm6.cohort_month
    left join retention_month_12 rm12 on cs.cohort_month = rm12.cohort_month
)

select * from final
order by cohort_month
EOF

# Run dbt for all cohort models
dbt run --select +cohort_retention +cohort_revenue +cohort_summary

echo "Solution complete!"
