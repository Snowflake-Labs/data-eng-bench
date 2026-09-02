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

python3 << 'PYEOF'
import os
import sys
import pandas as pd
from datetime import datetime, date

DB_TYPE = os.environ.get('DB_TYPE', 'duckdb').lower()

def get_connection():
    """Create a database connection based on DB_TYPE."""
    if DB_TYPE == 'snowflake':
        import base64
        import snowflake.connector
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives import serialization

        private_key_b64 = os.environ.get('SNOWFLAKE_PRIVATE_KEY', '')
        if not private_key_b64:
            raise ValueError("SNOWFLAKE_PRIVATE_KEY not found")
        private_key_pem = base64.b64decode(private_key_b64)
        passphrase = os.environ.get('SNOWFLAKE_PRIVATE_KEY_PASSPHRASE', '')
        passphrase_bytes = passphrase.encode() if passphrase else None
        p_key = serialization.load_pem_private_key(
            private_key_pem, password=passphrase_bytes, backend=default_backend()
        )
        pkb = p_key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption()
        )

        conn = snowflake.connector.connect(
            account=os.environ['SNOWFLAKE_ACCOUNT'],
            **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
            user=os.environ['SNOWFLAKE_USER'],
            private_key=pkb,
            database=os.environ['SNOWFLAKE_DATABASE'],
            schema=os.environ.get('SNOWFLAKE_SCHEMA', 'main'),
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        return duckdb.connect(db_path, read_only=True)


def execute_query_df(conn, query):
    """Execute a query and return a pandas DataFrame."""
    if DB_TYPE == 'snowflake':
        cursor = conn.cursor()
        cursor.execute(query)
        columns = [desc[0] for desc in cursor.description]
        rows = cursor.fetchall()
        return pd.DataFrame(rows, columns=columns)
    else:
        return conn.execute(query).fetchdf()


def generate_late_order_adjustments(output_path):
    """
    Identify late-arriving orders and generate GL adjustment entries.
    """
    conn = get_connection()

    # Get GL periods and create a lookup
    gl_periods_df = execute_query_df(conn, """
        SELECT
            PERIOD_ID,
            PERIOD_NAME,
            FISCAL_YEAR,
            FISCAL_MONTH,
            CAST(START_DATE AS DATE) AS START_DATE,
            CAST(END_DATE AS DATE) AS END_DATE,
            STATUS
        FROM FINANCE.GL_PERIODS
        ORDER BY START_DATE
    """)

    # Create a function to get period for a given date
    def get_period_for_date(date_val):
        """Get the GL period for a given date, generating synthetic period if needed."""
        if pd.isna(date_val):
            return None, None

        # Convert to date if timestamp
        if isinstance(date_val, pd.Timestamp):
            date_val = date_val.date()
        elif isinstance(date_val, datetime):
            date_val = date_val.date()
        elif isinstance(date_val, str):
            date_val = pd.to_datetime(date_val).date()

        # Check if date falls within existing GL periods
        for _, period in gl_periods_df.iterrows():
            start = period['START_DATE']
            end = period['END_DATE']
            if isinstance(start, pd.Timestamp):
                start = start.date()
            elif isinstance(start, str):
                start = pd.to_datetime(start).date()
            elif isinstance(start, datetime):
                start = start.date()
            if isinstance(end, pd.Timestamp):
                end = end.date()
            elif isinstance(end, str):
                end = pd.to_datetime(end).date()
            elif isinstance(end, datetime):
                end = end.date()

            if start <= date_val <= end:
                return period['PERIOD_ID'], period['PERIOD_NAME']

        # Generate synthetic period name based on date (YYYY-MM format)
        period_name = date_val.strftime('%Y-%m')
        period_id = f'SYNTHETIC-{period_name}'
        return period_id, period_name

    # Get late-arriving orders with valid statuses
    # Use DATEDIFF which works on both DuckDB and Snowflake
    late_orders_df = execute_query_df(conn, """
        SELECT
            o.ORDER_ID,
            o.ORDER_NUMBER,
            CAST(o.ORDERED_AT AS TIMESTAMP) AS ORDERED_AT,
            CAST(o.CREATED_AT AS TIMESTAMP) AS CREATED_AT,
            o.GRAND_TOTAL,
            o.CURRENCY_CODE,
            COALESCE(NULLIF(o.EXCHANGE_RATE, 0), 1.0) as EXCHANGE_RATE,
            o.STATUS
        FROM ORDERS.ORDERS o
        WHERE o.STATUS IN ('COMPLETED', 'DELIVERED', 'SHIPPED')
        AND o.ORDERED_AT < o.CREATED_AT
        AND DATEDIFF('day', o.ORDERED_AT, o.CREATED_AT) > 0
        ORDER BY o.ORDERED_AT
    """)

    conn.close()

    print(f"Found {len(late_orders_df)} late-arriving orders")

    # Process each late order to find those crossing period boundaries
    adjustments = []

    for _, order in late_orders_df.iterrows():
        ordered_period_id, ordered_period_name = get_period_for_date(order['ORDERED_AT'])
        created_period_id, created_period_name = get_period_for_date(order['CREATED_AT'])

        # Skip if both dates are in the same period
        if ordered_period_name == created_period_name:
            continue

        # Skip if ordered date is AFTER created date (data quality issue - shouldn't happen)
        ordered_at = order['ORDERED_AT']
        created_at = order['CREATED_AT']
        if isinstance(ordered_at, str):
            ordered_at = pd.to_datetime(ordered_at)
        if isinstance(created_at, str):
            created_at = pd.to_datetime(created_at)
        if ordered_at > created_at:
            continue

        # Calculate USD amount
        grand_total = float(order['GRAND_TOTAL']) if order['GRAND_TOTAL'] is not None else 0.0
        exchange_rate = float(order['EXCHANGE_RATE']) if order['EXCHANGE_RATE'] is not None else 1.0
        amount_usd = grand_total * exchange_rate

        ordered_date = order['ORDERED_AT']
        if isinstance(ordered_date, pd.Timestamp):
            ordered_date_str = ordered_date.strftime('%Y-%m-%d')
        elif isinstance(ordered_date, str):
            ordered_date_str = str(ordered_date)[:10]
        else:
            ordered_date_str = str(ordered_date)[:10]

        variance_reason = f"Order dated {ordered_date_str} entered in period {created_period_name}"

        # Generate REVERSAL entry for created_at period (negative - remove revenue)
        adjustments.append({
            'period_id': created_period_id,
            'period_name': created_period_name,
            'adjustment_type': 'REVERSAL',
            'order_id': order['ORDER_ID'],
            'original_amount_local': grand_total,
            'adjusted_amount_usd': -amount_usd,  # Negative for reversal
            'variance_reason': variance_reason
        })

        # Generate RECOGNITION entry for ordered_at period (positive - add revenue)
        adjustments.append({
            'period_id': ordered_period_id,
            'period_name': ordered_period_name,
            'adjustment_type': 'RECOGNITION',
            'order_id': order['ORDER_ID'],
            'original_amount_local': grand_total,
            'adjusted_amount_usd': amount_usd,  # Positive for recognition
            'variance_reason': variance_reason
        })

    if not adjustments:
        # Create empty output with correct columns
        output_df = pd.DataFrame({
            'period_id': ['TOTAL'],
            'period_name': ['TOTAL'],
            'adjustment_type': ['SUMMARY'],
            'order_count': [0],
            'original_amount_local': [0.0],
            'adjusted_amount_usd': [0.0],
            'variance_reason': ['No late-arriving orders found']
        })
    else:
        adjustments_df = pd.DataFrame(adjustments)

        # Aggregate by period and adjustment type
        aggregated = adjustments_df.groupby(['period_id', 'period_name', 'adjustment_type']).agg({
            'order_id': 'count',
            'original_amount_local': 'sum',
            'adjusted_amount_usd': 'sum',
            'variance_reason': 'first'  # Take first variance reason as example
        }).reset_index()

        aggregated = aggregated.rename(columns={'order_id': 'order_count'})

        # Create variance reason summary
        aggregated['variance_reason'] = aggregated.apply(
            lambda row: f"Late orders adjustment: {row['order_count']} order(s)",
            axis=1
        )

        # Sort by period_name, then adjustment_type
        aggregated = aggregated.sort_values(['period_name', 'adjustment_type'])

        # Add TOTAL row
        total_row = pd.DataFrame([{
            'period_id': 'TOTAL',
            'period_name': 'TOTAL',
            'adjustment_type': 'SUMMARY',
            'order_count': int(aggregated['order_count'].sum() / 2),  # Each order has 2 entries
            'original_amount_local': aggregated[aggregated['adjustment_type'] == 'RECOGNITION']['original_amount_local'].sum(),
            'adjusted_amount_usd': aggregated['adjusted_amount_usd'].sum(),  # Should be ~0 if balanced
            'variance_reason': 'Net adjustment across all periods'
        }])

        output_df = pd.concat([aggregated, total_row], ignore_index=True)

    # Round monetary values
    output_df['original_amount_local'] = output_df['original_amount_local'].round(2)
    output_df['adjusted_amount_usd'] = output_df['adjusted_amount_usd'].round(2)

    # Select final columns
    output_df = output_df[[
        'period_id',
        'period_name',
        'adjustment_type',
        'order_count',
        'original_amount_local',
        'adjusted_amount_usd',
        'variance_reason'
    ]]

    # Write to CSV
    output_df.to_csv(output_path, index=False)

    print(f"Output written to {output_path}")
    print(f"Total adjustment rows: {len(output_df)}")
    print(f"Total orders requiring adjustment: {output_df[output_df['period_id'] == 'TOTAL']['order_count'].iloc[0]}")
    print(f"Net adjustment (should be ~0): ${output_df[output_df['period_id'] == 'TOTAL']['adjusted_amount_usd'].iloc[0]:,.2f}")

if __name__ == "__main__":
    generate_late_order_adjustments(
        output_path="/app/late_orders_adjustments.csv"
    )
PYEOF
