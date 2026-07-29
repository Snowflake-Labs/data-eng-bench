#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
fi

# Pre-create lowercase "main" schema using admin role (agent role lacks CREATE SCHEMA)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Pre-creating lowercase main schema using admin role..."
    python3 << 'PRECREATE_PY'
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
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
db = os.environ['SNOWFLAKE_DATABASE']
agent_role = os.environ['SNOWFLAKE_AGENT_ROLE']
try:
    cur.execute(f'CREATE SCHEMA IF NOT EXISTS {db}."main"')
    cur.execute(f'GRANT USAGE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE TABLE ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT CREATE VIEW ON SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT SELECT ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    cur.execute(f'GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {db}."main" TO ROLE {agent_role}')
    print(f"Successfully pre-created schema main in {db}")
except Exception as e:
    print(f"Warning: Failed to pre-create schema: {e}")
conn.close()
PRECREATE_PY
fi



# Create custom schema using admin role (agent role lacks CREATE SCHEMA privilege)
if [ "$DB_TYPE" = "snowflake" ] && [ -n "${SNOWFLAKE_ADMIN_ROLE:-}" ]; then
    echo "Creating custom schema using admin role..."
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
    host=os.environ.get('SNOWFLAKE_HOST') or None,
    user=os.environ['SNOWFLAKE_USER'],
    private_key=pkb,
    warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
    role=os.environ['SNOWFLAKE_ADMIN_ROLE'],
    database=os.environ['SNOWFLAKE_DATABASE'],
)
cur = conn.cursor()
schema = 'fraud_analytics'
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
mkdir -p dbt_project/{models/staging,models/marts}

# Create profiles.yml based on database type
mkdir -p ~/.dbt

if [ "$DB_TYPE" = "snowflake" ]; then
    # Decode private key from base64 and write to temp file
    PRIVATE_KEY_PATH="/tmp/snowflake_private_key.p8"
    echo "$SNOWFLAKE_PRIVATE_KEY" | base64 -d > "$PRIVATE_KEY_PATH"
    chmod 600 "$PRIVATE_KEY_PATH"

    cat > ~/.dbt/profiles.yml <<PROFILES
dbt_project:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: ${SNOWFLAKE_ACCOUNT}
      user: ${SNOWFLAKE_USER}
      private_key_path: ${PRIVATE_KEY_PATH}
      private_key_passphrase: ${SNOWFLAKE_PRIVATE_KEY_PASSPHRASE:-}
      database: ${SNOWFLAKE_DATABASE}
      schema: fraud_analytics
      warehouse: ${SNOWFLAKE_WAREHOUSE}
      role: ${SNOWFLAKE_ROLE:-}
      threads: 4
PROFILES
    echo "Configured Snowflake profile with database: $SNOWFLAKE_DATABASE"
else
    cat > ~/.dbt/profiles.yml << 'EOF'
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: fraud_analytics
EOF
    echo "Configured DuckDB profile"
fi

# Create dbt_project.yml
cat > dbt_project/dbt_project.yml << 'EOF'
name: 'dbt_project'
version: '1.0.0'
config-version: 2
profile: 'dbt_project'

model-paths: ["models"]

models:
  dbt_project:
    staging:
      +materialized: view
    marts:
      +materialized: table
EOF

# Create sources.yml
cat > dbt_project/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: orders
    schema: ORDERS
    tables:
      - name: order_payments
      - name: orders
      - name: order_fraud_scores
EOF

# Create staging model for payments
cat > dbt_project/models/staging/stg_order_payments.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(payment_id) as payment_id,
    trim(order_id) as order_id,
    trim(payment_method_id) as payment_method_id,
    trim(payment_method) as payment_method,
    amount,
    trim(currency_code) as currency_code,
    trim(status) as status,
    trim(transaction_id) as transaction_id,
    trim(authorization_code) as authorization_code,
    trim(card_last_four) as card_last_four,
    trim(card_type) as card_type,
    processed_at,
    created_at,
    updated_at
from {{ source('orders', 'order_payments') }}
EOF

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
    trim(order_number) as order_number,
    trim(status) as status,
    grand_total,
    ordered_at,
    created_at,
    updated_at
from {{ source('orders', 'orders') }}
EOF

# Create staging model for fraud scores
cat > dbt_project/models/staging/stg_order_fraud_scores.sql << 'EOF'
{{
    config(
        materialized='view'
    )
}}

select
    trim(fraud_score_id) as fraud_score_id,
    trim(order_id) as order_id,
    score,
    trim(risk_level) as risk_level,
    trim(provider) as provider,
    rule_hits,
    trim(ip_country) as ip_country,
    trim(reviewed_by) as reviewed_by,
    reviewed_at,
    created_at
from {{ source('orders', 'order_fraud_scores') }}
EOF

# Create payment_method_summary model
cat > dbt_project/models/marts/payment_method_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
 * Payment Method Summary
 * Aggregates payment metrics by payment method
 */

with payments as (
    select * from {{ ref('stg_order_payments') }}
),

aggregated as (
    select
        payment_method,
        count(*) as total_transactions,
        round(sum(amount), 4) as total_amount,
        round(avg(amount), 4) as avg_transaction_amount,
        sum(case when status in ('CAPTURED', 'COMPLETED') then 1 else 0 end) as success_count,
        sum(case when status = 'FAILED' then 1 else 0 end) as failed_count,
        sum(case when status in ('PENDING', 'AUTHORIZED') then 1 else 0 end) as pending_count
    from payments
    group by payment_method
)

select
    payment_method,
    total_transactions,
    total_amount,
    avg_transaction_amount,
    success_count,
    failed_count,
    pending_count,
    round(cast(failed_count as double) / total_transactions, 4) as failure_rate
from aggregated
order by total_transactions desc
EOF

# Create customer_payment_velocity model - use Jinja for db-specific date diff
cat > dbt_project/models/marts/customer_payment_velocity.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
 * Customer Payment Velocity
 * Calculates payment velocity metrics per customer to detect unusual patterns
 */

with payments as (
    select * from {{ ref('stg_order_payments') }}
),

orders as (
    select * from {{ ref('stg_orders') }}
),

customer_payments as (
    select
        o.customer_id,
        p.payment_id,
        p.amount,
        p.payment_method,
        p.processed_at
    from payments p
    join orders o on p.order_id = o.order_id
    where o.customer_id is not null
),

customer_metrics as (
    select
        customer_id,
        count(*) as total_payments,
        round(sum(amount), 4) as total_amount,
        count(distinct payment_method) as distinct_payment_methods,
        min(cast(processed_at as date)) as first_payment_date,
        max(cast(processed_at as date)) as last_payment_date,
        max(amount) as max_single_payment
    from customer_payments
    group by customer_id
),

with_velocity as (
    select
        customer_id,
        total_payments,
        total_amount,
        distinct_payment_methods,
        first_payment_date,
        last_payment_date,
        {% if target.type == 'snowflake' %}
        greatest(1, datediff('day', first_payment_date, last_payment_date)) as days_active,
        round(cast(total_payments as double) / greatest(1, datediff('day', first_payment_date, last_payment_date)), 4) as payments_per_day,
        round(total_amount / greatest(1, datediff('day', first_payment_date, last_payment_date)), 4) as amount_per_day,
        {% else %}
        greatest(1, last_payment_date - first_payment_date) as days_active,
        round(cast(total_payments as double) / greatest(1, last_payment_date - first_payment_date), 4) as payments_per_day,
        round(total_amount / greatest(1, last_payment_date - first_payment_date), 4) as amount_per_day,
        {% endif %}
        max_single_payment
    from customer_metrics
)

select
    customer_id,
    total_payments,
    total_amount,
    distinct_payment_methods,
    first_payment_date,
    last_payment_date,
    days_active,
    payments_per_day,
    amount_per_day,
    max_single_payment,
    case
        when payments_per_day > 0.5 or amount_per_day > 500 then true
        else false
    end as is_high_velocity
from with_velocity
EOF

# Create fraud_risk_summary model
cat > dbt_project/models/marts/fraud_risk_summary.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
 * Fraud Risk Summary
 * Aggregates fraud metrics for executive reporting
 */

with fraud_scores as (
    select * from {{ ref('stg_order_fraud_scores') }}
),

payments as (
    select * from {{ ref('stg_order_payments') }}
),

order_payments_agg as (
    select
        order_id,
        sum(amount) as total_amount,
        sum(case when status = 'FAILED' then 1 else 0 end) as failed_count
    from payments
    group by order_id
),

fraud_with_payments as (
    select
        f.risk_level,
        f.order_id,
        f.score,
        coalesce(p.total_amount, 0) as payment_amount,
        coalesce(p.failed_count, 0) as failed_count
    from fraud_scores f
    left join order_payments_agg p on f.order_id = p.order_id
),

total_orders as (
    select count(*) as total_count from fraud_scores
)

select
    f.risk_level,
    count(*) as order_count,
    round(sum(f.payment_amount), 4) as total_payment_amount,
    round(avg(f.score), 4) as avg_fraud_score,
    sum(case when f.failed_count > 0 then 1 else 0 end) as failed_payment_count,
    round(cast(count(*) as double) / t.total_count, 4) as pct_of_total_orders
from fraud_with_payments f
cross join total_orders t
group by f.risk_level, t.total_count
order by
    case f.risk_level
        when 'LOW' then 1
        when 'MEDIUM' then 2
        when 'HIGH' then 3
        when 'CRITICAL' then 4
    end
EOF

# Create payment_anomalies model
cat > dbt_project/models/marts/payment_anomalies.sql << 'EOF'
{{
    config(
        materialized='table'
    )
}}

/*
 * Payment Anomalies
 * Identifies anomalous payment patterns based on statistical thresholds
 */

with payments as (
    select * from {{ ref('stg_order_payments') }}
),

orders as (
    select * from {{ ref('stg_orders') }}
),

fraud_scores as (
    select * from {{ ref('stg_order_fraud_scores') }}
),

high_velocity_customers as (
    select customer_id
    from {{ ref('customer_payment_velocity') }}
    where is_high_velocity = true
),

payment_with_context as (
    select
        p.payment_id,
        p.order_id,
        o.customer_id,
        p.payment_method,
        p.amount,
        p.processed_at,
        p.status,
        coalesce(f.score, 0) as fraud_score,
        f.risk_level,
        case when hv.customer_id is not null then true else false end as is_high_velocity_customer
    from payments p
    join orders o on p.order_id = o.order_id
    left join fraud_scores f on p.order_id = f.order_id
    left join high_velocity_customers hv on o.customer_id = hv.customer_id
),

with_flags as (
    select
        payment_id,
        order_id,
        customer_id,
        payment_method,
        amount,
        processed_at,
        fraud_score,
        risk_level,
        -- Individual flag checks
        case when amount > 1000 then 1 else 0 end as flag_high_amount,
        case when fraud_score > 70 then 1 else 0 end as flag_high_fraud_score,
        case when risk_level in ('CRITICAL', 'HIGH') then 1 else 0 end as flag_critical_risk,
        case when status = 'FAILED' then 1 else 0 end as flag_failed_payment,
        case when is_high_velocity_customer then 1 else 0 end as flag_high_velocity
    from payment_with_context
),

with_anomaly_flags as (
    select
        payment_id,
        order_id,
        customer_id,
        payment_method,
        amount,
        processed_at,
        fraud_score,
        risk_level,
        flag_high_amount,
        flag_high_fraud_score,
        flag_critical_risk,
        flag_failed_payment,
        flag_high_velocity,
        -- Build comma-separated flags string
        {% if target.type == 'snowflake' %}
        ARRAY_TO_STRING(
            ARRAY_COMPACT(
                ARRAY_CONSTRUCT(
                    case when flag_high_amount = 1 then 'HIGH_AMOUNT' end,
                    case when flag_high_fraud_score = 1 then 'HIGH_FRAUD_SCORE' end,
                    case when flag_critical_risk = 1 then 'CRITICAL_RISK' end,
                    case when flag_failed_payment = 1 then 'FAILED_PAYMENT' end,
                    case when flag_high_velocity = 1 then 'HIGH_VELOCITY_CUSTOMER' end
                )
            ),
            ','
        ) as anomaly_flags,
        {% else %}
        concat_ws(',',
            case when flag_high_amount = 1 then 'HIGH_AMOUNT' else null end,
            case when flag_high_fraud_score = 1 then 'HIGH_FRAUD_SCORE' else null end,
            case when flag_critical_risk = 1 then 'CRITICAL_RISK' else null end,
            case when flag_failed_payment = 1 then 'FAILED_PAYMENT' else null end,
            case when flag_high_velocity = 1 then 'HIGH_VELOCITY_CUSTOMER' else null end
        ) as anomaly_flags,
        {% endif %}
        flag_high_amount + flag_high_fraud_score + flag_critical_risk +
            flag_failed_payment + flag_high_velocity as anomaly_count
    from with_flags
)

select
    payment_id,
    order_id,
    customer_id,
    payment_method,
    amount,
    processed_at,
    fraud_score,
    risk_level,
    anomaly_flags,
    anomaly_count
from with_anomaly_flags
where anomaly_count > 0
order by anomaly_count desc, amount desc
EOF

cd dbt_project
dbt build


# Snowflake note: Tests use lower(table_schema) with 'fraud_analytics' schema
# and query FROM fraud_analytics.<table> - both work naturally with Snowflake's
# uppercase storage. No lowercase views needed.

echo "Solution complete!"
