#!/bin/bash
set -e

# Source Snowflake env vars if available (set by entrypoint)
if [ -f /tmp/snowflake_env.sh ]; then
    echo "Loading Snowflake environment from entrypoint..."
    source /tmp/snowflake_env.sh
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
schema = 'gl_analytics'
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
mkdir -p dbt_project/{models/staging,models/intermediate,models/marts}

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
      schema: gl_analytics
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
      schema: gl_analytics
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
    intermediate:
      +materialized: view
    marts:
      +materialized: table
EOF

# Create sources.yml
cat > dbt_project/models/staging/sources.yml << 'EOF'
version: 2

sources:
  - name: finance
    schema: FINANCE
    tables:
      - name: GL_TRANSACTIONS
      - name: CHART_OF_ACCOUNTS
      - name: GL_PERIODS
EOF

# Create staging models
cat > dbt_project/models/staging/stg_gl_transactions.sql << 'EOF'
select
    TRANSACTION_ID as transaction_id,
    TRANSACTION_NUMBER as transaction_number,
    ACCOUNT_ID as account_id,
    PERIOD_ID as period_id,
    TRANSACTION_DATE as transaction_date,
    COALESCE(DEBIT_AMOUNT, 0) as debit_amount,
    COALESCE(CREDIT_AMOUNT, 0) as credit_amount,
    DESCRIPTION as description,
    REFERENCE_TYPE as reference_type,
    REFERENCE_ID as reference_id,
    CREATED_BY as created_by,
    CREATED_AT as created_at
from {{ source('finance', 'GL_TRANSACTIONS') }}
EOF

cat > dbt_project/models/staging/stg_chart_of_accounts.sql << 'EOF'
select
    ACCOUNT_ID as account_id,
    ACCOUNT_NUMBER as account_number,
    ACCOUNT_NAME as account_name,
    ACCOUNT_TYPE as account_type,
    ACCOUNT_SUBTYPE as account_subtype,
    PARENT_ACCOUNT_ID as parent_account_id,
    IS_ACTIVE as is_active,
    CREATED_AT as created_at
from {{ source('finance', 'CHART_OF_ACCOUNTS') }}
EOF

cat > dbt_project/models/staging/stg_gl_periods.sql << 'EOF'
select
    PERIOD_ID as period_id,
    FISCAL_YEAR as fiscal_year,
    FISCAL_QUARTER as fiscal_quarter,
    FISCAL_MONTH as fiscal_month,
    PERIOD_NAME as period_name,
    START_DATE as start_date,
    END_DATE as end_date,
    STATUS as status,
    CREATED_AT as created_at
from {{ source('finance', 'GL_PERIODS') }}
EOF

# Create intermediate model for account transaction summaries
cat > dbt_project/models/intermediate/int_account_transaction_summary.sql << 'EOF'
/*
    Intermediate model that aggregates transactions by account
*/
select
    gl.account_id,
    coa.account_number,
    coa.account_name,
    coa.account_type,
    coa.account_subtype,
    ROUND(SUM(gl.debit_amount), 4) as total_debits,
    ROUND(SUM(gl.credit_amount), 4) as total_credits
from {{ ref('stg_gl_transactions') }} gl
inner join {{ ref('stg_chart_of_accounts') }} coa
    on gl.account_id = coa.account_id
group by
    gl.account_id,
    coa.account_number,
    coa.account_name,
    coa.account_type,
    coa.account_subtype
EOF

# Create mart models
cat > dbt_project/models/marts/account_balances.sql << 'EOF'
/*
    Account balances with natural balance direction calculation

    - ASSET and EXPENSE: net_balance = debits - credits (positive = normal)
    - LIABILITY, EQUITY, REVENUE: net_balance = credits - debits (positive = normal)
*/
select
    account_id,
    account_number,
    account_name,
    account_type,
    total_debits,
    total_credits,
    ROUND(
        case
            when account_type in ('ASSET', 'EXPENSE') then total_debits - total_credits
            else total_credits - total_debits
        end,
        4
    ) as net_balance
from {{ ref('int_account_transaction_summary') }}
EOF

cat > dbt_project/models/marts/trial_balance.sql << 'EOF'
/*
    Trial balance summary

    Aggregates account balances to verify debits = credits
    Positive net_balance goes to debit side, negative to credit side
*/
with account_balances as (
    select * from {{ ref('account_balances') }}
),

balance_sides as (
    select
        case when net_balance > 0 then net_balance else 0 end as debit_balance,
        case when net_balance < 0 then ABS(net_balance) else 0 end as credit_balance
    from account_balances
)

select
    ROUND(SUM(debit_balance), 4) as total_debit_balances,
    ROUND(SUM(credit_balance), 4) as total_credit_balances,
    ROUND(SUM(debit_balance) - SUM(credit_balance), 4) as difference,
    ABS(SUM(debit_balance) - SUM(credit_balance)) <= 0.01 as is_balanced
from balance_sides
EOF

cat > dbt_project/models/marts/out_of_balance_entries.sql << 'EOF'
/*
    Identify journal entries where debits != credits

    Groups by transaction_number and checks for imbalance
*/
with entry_totals as (
    select
        transaction_number,
        MIN(transaction_date) as entry_date,
        ROUND(SUM(debit_amount), 4) as total_debits,
        ROUND(SUM(credit_amount), 4) as total_credits,
        COUNT(*) as line_count
    from {{ ref('stg_gl_transactions') }}
    group by transaction_number
)

select
    transaction_number,
    entry_date,
    total_debits,
    total_credits,
    ROUND(ABS(total_debits - total_credits), 4) as imbalance_amount,
    line_count
from entry_totals
where ABS(total_debits - total_credits) > 0.01
EOF

cat > dbt_project/models/marts/unusual_balance_accounts.sql << 'EOF'
/*
    Identify accounts with balances in unusual directions

    Expected balance directions:
    - ASSET (non-CONTRA): DEBIT (positive net_balance)
    - ASSET CONTRA: CREDIT (negative net_balance)
    - LIABILITY: CREDIT (negative net_balance when calculated as debits - credits)
    - EQUITY: CREDIT (negative net_balance when calculated as debits - credits)
    - REVENUE (non-CONTRA): CREDIT (negative net_balance when calculated as debits - credits)
    - REVENUE CONTRA: DEBIT (positive net_balance)
    - EXPENSE: DEBIT (positive net_balance)
*/
with account_data as (
    select
        ats.account_id,
        ats.account_number,
        ats.account_name,
        ats.account_type,
        ats.account_subtype,
        -- Calculate raw balance (debits - credits) to determine actual direction
        ROUND(ats.total_debits - ats.total_credits, 4) as raw_balance
    from {{ ref('int_account_transaction_summary') }} ats
),

with_directions as (
    select
        account_id,
        account_number,
        account_name,
        account_type,
        account_subtype,
        raw_balance as net_balance,
        -- Expected direction based on account type and subtype
        case
            when account_type = 'ASSET' and COALESCE(account_subtype, '') = 'CONTRA' then 'CREDIT'
            when account_type = 'ASSET' then 'DEBIT'
            when account_type = 'LIABILITY' then 'CREDIT'
            when account_type = 'EQUITY' then 'CREDIT'
            when account_type = 'REVENUE' and COALESCE(account_subtype, '') = 'CONTRA' then 'DEBIT'
            when account_type = 'REVENUE' then 'CREDIT'
            when account_type = 'EXPENSE' then 'DEBIT'
            else 'UNKNOWN'
        end as expected_direction,
        -- Actual direction based on raw balance
        case
            when raw_balance > 0.01 then 'DEBIT'
            when raw_balance < -0.01 then 'CREDIT'
            else 'ZERO'
        end as actual_direction
    from account_data
)

select
    account_id,
    account_number,
    account_name,
    account_type,
    account_subtype,
    net_balance,
    expected_direction,
    actual_direction,
    true as is_unusual
from with_directions
where actual_direction != 'ZERO'
  and actual_direction != expected_direction
EOF

cat > dbt_project/models/marts/period_summary.sql << 'EOF'
/*
    Period summary - GL activity by fiscal period with period-over-period changes
*/
with period_totals as (
    select
        p.period_id,
        p.period_name,
        p.fiscal_year,
        p.fiscal_quarter,
        p.fiscal_month,
        p.start_date,
        p.end_date,
        p.status as period_status,
        COALESCE(ROUND(SUM(gl.debit_amount), 4), 0) as total_debits,
        COALESCE(ROUND(SUM(gl.credit_amount), 4), 0) as total_credits,
        COALESCE(ROUND(SUM(gl.debit_amount) - SUM(gl.credit_amount), 4), 0) as net_activity,
        COALESCE(COUNT(gl.transaction_id), 0) as transaction_count
    from {{ ref('stg_gl_periods') }} p
    left join {{ ref('stg_gl_transactions') }} gl
        on p.period_id = gl.period_id
    group by
        p.period_id,
        p.period_name,
        p.fiscal_year,
        p.fiscal_quarter,
        p.fiscal_month,
        p.start_date,
        p.end_date,
        p.status
),

with_prior_period as (
    select
        pt.*,
        LAG(pt.net_activity) OVER (ORDER BY pt.fiscal_year, pt.fiscal_month) as prior_period_net_activity
    from period_totals pt
)

select
    period_id,
    period_name,
    fiscal_year,
    fiscal_quarter,
    fiscal_month,
    start_date,
    end_date,
    period_status,
    total_debits,
    total_credits,
    net_activity,
    transaction_count,
    COALESCE(prior_period_net_activity, 0) as prior_period_net_activity,
    ROUND(net_activity - COALESCE(prior_period_net_activity, 0), 4) as activity_change
from with_prior_period
order by fiscal_year, fiscal_month
EOF

cd dbt_project
dbt run

echo "Solution complete!"
