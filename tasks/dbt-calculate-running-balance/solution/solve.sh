#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Create custom schema using admin role (agent role lacks CREATE SCHEMA privilege)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Creating custom schema 'finance_analytics' using admin role..."
    python3 << 'CREATE_SCHEMA_PY'
import snowflake.connector, os, base64
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

pk_b64 = os.environ['SNOWFLAKE_PRIVATE_KEY']
pk_pem = base64.b64decode(pk_b64)
pp = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
pp_bytes = pp.encode() if pp else None
p_key = serialization.load_pem_private_key(pk_pem, password=pp_bytes, backend=default_backend())
pkb = p_key.private_bytes(encoding=serialization.Encoding.DER, format=serialization.PrivateFormat.PKCS8, encryption_algorithm=serialization.NoEncryption())

conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
schema = 'finance_analytics'
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
db = os.environ['SNOWFLAKE_DATABASE']
try:
    cur.execute(f"CREATE SCHEMA IF NOT EXISTS {db}.{schema}")
    cur.execute(f"GRANT USAGE ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE TABLE ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT CREATE VIEW ON SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT SELECT ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}")
    cur.execute(f"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}.{schema} TO ROLE {agent_role}")
    print(f"Successfully created schema {schema} and granted permissions to {agent_role}")
except Exception as e:
    print(f"Warning: Failed to create schema {schema}: {e}")
conn.close()
CREATE_SCHEMA_PY
fi

# Determine database type (default to duckdb)
DB_TYPE="${DB_TYPE:-duckdb}"
echo "Database type: $DB_TYPE"

cd /app

# Create dbt project structure
mkdir -p dbt_project/{models/staging,models/marts,macros/utils}

# Create profiles.yml based on database type
mkdir -p ~/.dbt

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > dbt_project/profiles.yml <<PROFILES
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
      schema: finance_analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    cat > dbt_project/profiles.yml <<PROFILES
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: '${DUCKDB_PATH}'
      schema: finance_analytics
      threads: 4
PROFILES
    echo "Configured DuckDB profile"
fi

export DBT_PROFILES_DIR="/app/dbt_project"

# Create dbt_project.yml
cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'retail_dw_master'

model-paths: ["models"]
macro-paths: ["macros"]

models:
  dbt_project:
    staging:
      +materialized: view
    marts:
      +materialized: table
EOF

# Create generate_schema_name macro to use schema from profiles.yml directly
cat > dbt_project/macros/utils/generate_schema_name.sql << 'MACRO'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
MACRO

# Create sources.yml - use DB_TYPE branching for different schemas
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > dbt_project/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: raw_orders
    schema: ORDERS
    tables:
      - name: ORDERS
  - name: raw_finance
    schema: FINANCE
    tables:
      - name: CUSTOMER_PAYMENTS
EOF
else
    cat > dbt_project/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: raw_orders
    schema: main
    tables:
      - name: ORDERS
  - name: raw_finance
    schema: main
    tables:
      - name: CUSTOMER_PAYMENTS
EOF
fi

# Create staging model for orders
cat > dbt_project/models/staging/stg_orders.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(order_id) as order_id,
    trim(customer_id) as customer_id,
    CAST(ordered_at AS DATE) as ordered_at,
    round(grand_total, 2) as grand_total,
    trim(status) as status
from {{ source('raw_orders', 'ORDERS') }}
where status not in ('CANCELLED', 'FAILED')
EOF

# Create staging model for payments
cat > dbt_project/models/staging/stg_payments.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(payment_id) as payment_id,
    trim(customer_id) as customer_id,
    CAST(payment_date AS DATE) as payment_date,
    round(amount, 2) as amount,
    trim(status) as status
from {{ source('raw_finance', 'CUSTOMER_PAYMENTS') }}
where status = 'POSTED'
EOF

# Create customer_running_balance model - DB_TYPE branching for date arithmetic and boolean expressions
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > dbt_project/models/marts/customer_running_balance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with orders_as_transactions as (
    select
        order_id as transaction_id,
        customer_id,
        'ORDER' as transaction_type,
        ordered_at as transaction_date,
        grand_total as transaction_amount
    from {{ ref('stg_orders') }}
),

payments_as_transactions as (
    select
        payment_id as transaction_id,
        customer_id,
        'PAYMENT' as transaction_type,
        payment_date as transaction_date,
        -1 * amount as transaction_amount
    from {{ ref('stg_payments') }}
),

all_transactions as (
    select * from orders_as_transactions
    union all
    select * from payments_as_transactions
),

with_running_balance as (
    select
        transaction_id,
        customer_id,
        transaction_type,
        transaction_date,
        transaction_amount,
        sum(transaction_amount) over (
            partition by customer_id
            order by transaction_date, transaction_id
            rows between unbounded preceding and current row
        ) as running_balance,
        row_number() over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as transaction_sequence,
        sum(case when transaction_type = 'ORDER' then 1 else 0 end) over (
            partition by customer_id
            order by transaction_date, transaction_id
            rows between unbounded preceding and current row
        ) as cumulative_orders,
        sum(case when transaction_type = 'PAYMENT' then 1 else 0 end) over (
            partition by customer_id
            order by transaction_date, transaction_id
            rows between unbounded preceding and current row
        ) as cumulative_payments,
        first_value(transaction_date) over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as first_transaction_date
    from all_transactions
),

with_previous_balance as (
    select
        *,
        coalesce(
            lag(running_balance) over (
                partition by customer_id
                order by transaction_date, transaction_id
            ),
            0
        ) as previous_balance,
        lag(transaction_type) over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as prev_transaction_type
    from with_running_balance
),

with_last_payment as (
    select
        t.*,
        max(case when t2.transaction_type = 'PAYMENT' then t2.transaction_date else null end) as last_payment_date
    from with_previous_balance t
    left join with_previous_balance t2
        on t.customer_id = t2.customer_id
        and (t2.transaction_date < t.transaction_date
             or (t2.transaction_date = t.transaction_date and t2.transaction_id < t.transaction_id))
    group by
        t.transaction_id,
        t.customer_id,
        t.transaction_type,
        t.transaction_date,
        t.transaction_amount,
        t.running_balance,
        t.transaction_sequence,
        t.cumulative_orders,
        t.cumulative_payments,
        t.first_transaction_date,
        t.previous_balance,
        t.prev_transaction_type
),

with_streak_groups as (
    select
        *,
        transaction_sequence -
            row_number() over (
                partition by customer_id, transaction_type
                order by transaction_date, transaction_id
            ) as streak_group
    from with_last_payment
),

with_streaks as (
    select
        transaction_id,
        customer_id,
        transaction_type,
        transaction_date,
        transaction_amount,
        running_balance,
        transaction_sequence,
        cumulative_orders,
        cumulative_payments,
        first_transaction_date,
        previous_balance,
        prev_transaction_type,
        last_payment_date,
        streak_group,
        row_number() over (
            partition by customer_id, transaction_type, streak_group
            order by transaction_date, transaction_id
        ) as streak_count
    from with_streak_groups
)

select
    transaction_id,
    customer_id,
    transaction_type,
    transaction_date,
    round(transaction_amount, 2) as transaction_amount,
    round(previous_balance, 2) as previous_balance,
    round(running_balance, 2) as running_balance,
    transaction_sequence,
    case
        when round(running_balance, 2) < 0 then 'CREDIT'
        when round(running_balance, 2) = 0 then 'ZERO'
        else 'DEBIT'
    end as balance_status,
    case
        when last_payment_date is not null
        then DATEDIFF('day', last_payment_date, transaction_date)
        else null
    end as days_since_last_payment,
    case when round(running_balance, 2) > 500 then 1 else 0 end as is_high_balance,
    case
        when round(running_balance, 2) > round(previous_balance, 2) then 'INCREASE'
        when round(running_balance, 2) < round(previous_balance, 2) then 'DECREASE'
        else 'NO_CHANGE'
    end as balance_change_direction,
    cumulative_orders,
    cumulative_payments,
    case when transaction_sequence = 1 then 1 else 0 end as is_first_transaction,
    case
        when round(running_balance, 2) < round(previous_balance, 2) then 'IMPROVING'
        when round(running_balance, 2) > round(previous_balance, 2) then 'WORSENING'
        else 'STABLE'
    end as balance_trend,
    case when transaction_type = 'ORDER' then streak_count else 0 end as consecutive_orders,
    case when transaction_type = 'PAYMENT' then streak_count else 0 end as consecutive_payments,
    DATEDIFF('day', first_transaction_date, transaction_date) as days_since_first_transaction
from with_streaks
order by customer_id, transaction_date, transaction_id
EOF
else
    # DuckDB version - uses date subtraction and boolean expressions
    cat > dbt_project/models/marts/customer_running_balance.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with orders_as_transactions as (
    select
        order_id as transaction_id,
        customer_id,
        'ORDER' as transaction_type,
        ordered_at as transaction_date,
        grand_total as transaction_amount
    from {{ ref('stg_orders') }}
),

payments_as_transactions as (
    select
        payment_id as transaction_id,
        customer_id,
        'PAYMENT' as transaction_type,
        payment_date as transaction_date,
        -1 * amount as transaction_amount
    from {{ ref('stg_payments') }}
),

all_transactions as (
    select * from orders_as_transactions
    union all
    select * from payments_as_transactions
),

with_running_balance as (
    select
        transaction_id,
        customer_id,
        transaction_type,
        transaction_date,
        transaction_amount,
        sum(transaction_amount) over (
            partition by customer_id
            order by transaction_date, transaction_id
            rows between unbounded preceding and current row
        ) as running_balance,
        row_number() over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as transaction_sequence,
        sum(case when transaction_type = 'ORDER' then 1 else 0 end) over (
            partition by customer_id
            order by transaction_date, transaction_id
            rows between unbounded preceding and current row
        ) as cumulative_orders,
        sum(case when transaction_type = 'PAYMENT' then 1 else 0 end) over (
            partition by customer_id
            order by transaction_date, transaction_id
            rows between unbounded preceding and current row
        ) as cumulative_payments,
        first_value(transaction_date) over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as first_transaction_date
    from all_transactions
),

with_previous_balance as (
    select
        *,
        coalesce(
            lag(running_balance) over (
                partition by customer_id
                order by transaction_date, transaction_id
            ),
            0
        ) as previous_balance,
        lag(transaction_type) over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as prev_transaction_type
    from with_running_balance
),

with_last_payment as (
    select
        t.*,
        max(case when t2.transaction_type = 'PAYMENT' then t2.transaction_date else null end) as last_payment_date
    from with_previous_balance t
    left join with_previous_balance t2
        on t.customer_id = t2.customer_id
        and (t2.transaction_date < t.transaction_date
             or (t2.transaction_date = t.transaction_date and t2.transaction_id < t.transaction_id))
    group by
        t.transaction_id,
        t.customer_id,
        t.transaction_type,
        t.transaction_date,
        t.transaction_amount,
        t.running_balance,
        t.transaction_sequence,
        t.cumulative_orders,
        t.cumulative_payments,
        t.first_transaction_date,
        t.previous_balance,
        t.prev_transaction_type
),

with_streak_groups as (
    select
        *,
        transaction_sequence -
            row_number() over (
                partition by customer_id, transaction_type
                order by transaction_date, transaction_id
            ) as streak_group
    from with_last_payment
),

with_streaks as (
    select
        transaction_id,
        customer_id,
        transaction_type,
        transaction_date,
        transaction_amount,
        running_balance,
        transaction_sequence,
        cumulative_orders,
        cumulative_payments,
        first_transaction_date,
        previous_balance,
        prev_transaction_type,
        last_payment_date,
        streak_group,
        row_number() over (
            partition by customer_id, transaction_type, streak_group
            order by transaction_date, transaction_id
        ) as streak_count
    from with_streak_groups
)

select
    transaction_id,
    customer_id,
    transaction_type,
    transaction_date,
    round(transaction_amount, 2) as transaction_amount,
    round(previous_balance, 2) as previous_balance,
    round(running_balance, 2) as running_balance,
    transaction_sequence,
    case
        when round(running_balance, 2) < 0 then 'CREDIT'
        when round(running_balance, 2) = 0 then 'ZERO'
        else 'DEBIT'
    end as balance_status,
    case
        when last_payment_date is not null
        then cast(transaction_date - last_payment_date as integer)
        else null
    end as days_since_last_payment,
    round(running_balance, 2) > 500 as is_high_balance,
    case
        when round(running_balance, 2) > round(previous_balance, 2) then 'INCREASE'
        when round(running_balance, 2) < round(previous_balance, 2) then 'DECREASE'
        else 'NO_CHANGE'
    end as balance_change_direction,
    cumulative_orders,
    cumulative_payments,
    transaction_sequence = 1 as is_first_transaction,
    case
        when round(running_balance, 2) < round(previous_balance, 2) then 'IMPROVING'
        when round(running_balance, 2) > round(previous_balance, 2) then 'WORSENING'
        else 'STABLE'
    end as balance_trend,
    case when transaction_type = 'ORDER' then streak_count else 0 end as consecutive_orders,
    case when transaction_type = 'PAYMENT' then streak_count else 0 end as consecutive_payments,
    cast(transaction_date - first_transaction_date as integer) as days_since_first_transaction
from with_streaks
order by customer_id, transaction_date, transaction_id
EOF
fi

# Create rpt_customer_account_summary model - DB_TYPE branching for date arithmetic
if [ "$DB_TYPE" = "snowflake" ]; then
    cat > dbt_project/models/marts/rpt_customer_account_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with running_balance as (
    select * from {{ ref('customer_running_balance') }}
),

last_transaction as (
    select
        customer_id,
        running_balance as final_balance,
        balance_status as final_status,
        transaction_date as last_transaction_date,
        row_number() over (
            partition by customer_id
            order by transaction_date desc, transaction_id desc
        ) as rn
    from running_balance
),

first_transaction as (
    select
        customer_id,
        transaction_date as first_transaction_date,
        row_number() over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as rn
    from running_balance
),

payment_gaps as (
    select
        customer_id,
        transaction_date,
        lag(transaction_date) over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as prev_payment_date
    from running_balance
    where transaction_type = 'PAYMENT'
),

avg_payment_gap as (
    select
        customer_id,
        avg(CAST(DATEDIFF('day', prev_payment_date, transaction_date) AS DOUBLE PRECISION)) as avg_days_between_payments
    from payment_gaps
    where prev_payment_date is not null
    group by customer_id
),

order_streaks as (
    select
        customer_id,
        max(consecutive_orders) as longest_order_streak
    from running_balance
    group by customer_id
),

customer_stats as (
    select
        customer_id,
        sum(case when transaction_type = 'ORDER' then 1 else 0 end) as total_orders,
        sum(case when transaction_type = 'PAYMENT' then 1 else 0 end) as total_payments,
        sum(case when transaction_type = 'ORDER' then transaction_amount else 0 end) as total_order_amount,
        sum(case when transaction_type = 'PAYMENT' then abs(transaction_amount) else 0 end) as total_payment_amount,
        max(running_balance) as max_balance_reached
    from running_balance
    group by customer_id
)

select
    s.customer_id,
    s.total_orders,
    s.total_payments,
    round(s.total_order_amount, 2) as total_order_amount,
    round(s.total_payment_amount, 2) as total_payment_amount,
    round(lt.final_balance, 2) as final_balance,
    lt.final_status,
    round(g.avg_days_between_payments, 2) as avg_days_between_payments,
    round(s.max_balance_reached, 2) as max_balance_reached,
    case
        when round(lt.final_balance, 2) <= 0 then 5
        when round(lt.final_balance, 2) <= 100 then 4
        when round(lt.final_balance, 2) <= 300 then 3
        when round(lt.final_balance, 2) <= 500 then 2
        else 1
    end as account_health_score,
    coalesce(os.longest_order_streak, 0) as longest_order_streak,
    DATEDIFF('day', ft.first_transaction_date, lt.last_transaction_date) as account_age_days
from customer_stats s
join last_transaction lt
    on s.customer_id = lt.customer_id
    and lt.rn = 1
join first_transaction ft
    on s.customer_id = ft.customer_id
    and ft.rn = 1
left join avg_payment_gap g
    on s.customer_id = g.customer_id
left join order_streaks os
    on s.customer_id = os.customer_id
order by s.customer_id
EOF
else
    # DuckDB version - uses date subtraction
    cat > dbt_project/models/marts/rpt_customer_account_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with running_balance as (
    select * from {{ ref('customer_running_balance') }}
),

last_transaction as (
    select
        customer_id,
        running_balance as final_balance,
        balance_status as final_status,
        transaction_date as last_transaction_date,
        row_number() over (
            partition by customer_id
            order by transaction_date desc, transaction_id desc
        ) as rn
    from running_balance
),

first_transaction as (
    select
        customer_id,
        transaction_date as first_transaction_date,
        row_number() over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as rn
    from running_balance
),

payment_gaps as (
    select
        customer_id,
        transaction_date,
        lag(transaction_date) over (
            partition by customer_id
            order by transaction_date, transaction_id
        ) as prev_payment_date
    from running_balance
    where transaction_type = 'PAYMENT'
),

avg_payment_gap as (
    select
        customer_id,
        avg(cast(transaction_date - prev_payment_date as double)) as avg_days_between_payments
    from payment_gaps
    where prev_payment_date is not null
    group by customer_id
),

order_streaks as (
    select
        customer_id,
        max(consecutive_orders) as longest_order_streak
    from running_balance
    group by customer_id
),

customer_stats as (
    select
        customer_id,
        sum(case when transaction_type = 'ORDER' then 1 else 0 end) as total_orders,
        sum(case when transaction_type = 'PAYMENT' then 1 else 0 end) as total_payments,
        sum(case when transaction_type = 'ORDER' then transaction_amount else 0 end) as total_order_amount,
        sum(case when transaction_type = 'PAYMENT' then abs(transaction_amount) else 0 end) as total_payment_amount,
        max(running_balance) as max_balance_reached
    from running_balance
    group by customer_id
)

select
    s.customer_id,
    s.total_orders,
    s.total_payments,
    round(s.total_order_amount, 2) as total_order_amount,
    round(s.total_payment_amount, 2) as total_payment_amount,
    round(lt.final_balance, 2) as final_balance,
    lt.final_status,
    round(g.avg_days_between_payments, 2) as avg_days_between_payments,
    round(s.max_balance_reached, 2) as max_balance_reached,
    case
        when round(lt.final_balance, 2) <= 0 then 5
        when round(lt.final_balance, 2) <= 100 then 4
        when round(lt.final_balance, 2) <= 300 then 3
        when round(lt.final_balance, 2) <= 500 then 2
        else 1
    end as account_health_score,
    coalesce(os.longest_order_streak, 0) as longest_order_streak,
    cast(lt.last_transaction_date - ft.first_transaction_date as integer) as account_age_days
from customer_stats s
join last_transaction lt
    on s.customer_id = lt.customer_id
    and lt.rn = 1
join first_transaction ft
    on s.customer_id = ft.customer_id
    and ft.rn = 1
left join avg_payment_gap g
    on s.customer_id = g.customer_id
left join order_streaks os
    on s.customer_id = os.customer_id
order by s.customer_id
EOF
fi

# Create rpt_risk_assessment model - ANSI SQL compatible for both backends
cat > dbt_project/models/marts/rpt_risk_assessment.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

with account_summary as (
    select * from {{ ref('rpt_customer_account_summary') }}
),

risk_factors as (
    select
        customer_id,
        final_balance,
        avg_days_between_payments,
        max_balance_reached,
        longest_order_streak,
        case
            when avg_days_between_payments is null then 'LOW'
            when avg_days_between_payments < 15 then 'HIGH'
            when avg_days_between_payments < 45 then 'MEDIUM'
            else 'LOW'
        end as payment_frequency,
        case
            when final_balance <= 0 then 'LOW'
            when max_balance_reached > 3 * final_balance then 'HIGH'
            when max_balance_reached > 1.5 * final_balance then 'MEDIUM'
            else 'LOW'
        end as balance_volatility,
        case
            when longest_order_streak >= 5 then 'HIGH'
            when longest_order_streak >= 3 then 'MEDIUM'
            else 'LOW'
        end as streak_risk
    from account_summary
),

with_scores as (
    select
        customer_id,
        final_balance,
        payment_frequency,
        balance_volatility,
        streak_risk,
        case payment_frequency when 'HIGH' then 3 when 'MEDIUM' then 2 else 1 end as pf_score,
        case balance_volatility when 'HIGH' then 4 when 'MEDIUM' then 2 else 1 end as bv_score,
        case streak_risk when 'HIGH' then 3 when 'MEDIUM' then 2 else 1 end as sr_score
    from risk_factors
)

select
    customer_id,
    round(final_balance, 2) as final_balance,
    payment_frequency,
    balance_volatility,
    streak_risk,
    pf_score + bv_score + sr_score as overall_risk_score,
    case
        when pf_score + bv_score + sr_score >= 9 then 'CRITICAL'
        when pf_score + bv_score + sr_score >= 7 then 'HIGH'
        when pf_score + bv_score + sr_score >= 5 then 'MEDIUM'
        else 'LOW'
    end as risk_category
from with_scores
order by customer_id
EOF

# Clean up existing tables/views (DuckDB only - avoid conflicts)
if [ "$DB_TYPE" = "duckdb" ]; then
    DUCKDB_PATH="${DUCKDB_PATH:-/app/database/retail.duckdb}"
    echo ">>> Cleaning up existing tables/views"
    duckdb "${DUCKDB_PATH}" << 'SQL'
DROP VIEW IF EXISTS finance_analytics.stg_orders;
DROP VIEW IF EXISTS finance_analytics.stg_payments;
DROP TABLE IF EXISTS finance_analytics.customer_running_balance;
DROP TABLE IF EXISTS finance_analytics.rpt_customer_account_summary;
DROP TABLE IF EXISTS finance_analytics.rpt_risk_assessment;
SQL
fi

cd dbt_project
dbt deps || true
dbt run --select +rpt_risk_assessment --full-refresh

echo "Solution complete!"
