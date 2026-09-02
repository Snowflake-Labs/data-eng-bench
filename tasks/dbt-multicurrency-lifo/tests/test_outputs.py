"""
Test verifier for Multi-Currency LIFO Inventory Costing task.
Validates LIFO logic, currency conversion, COGS calculations, weighted-average
fallback costing, and inventory turnover metrics by computing expected values
independently from source staging tables.
All checks are pass/fail with no partial scoring.
"""
import subprocess
import json
import os
from typing import List, Dict, Any, Tuple, Optional
from decimal import Decimal, ROUND_HALF_UP

# ============ DUAL-BACKEND INFRASTRUCTURE ============


def load_snowflake_env():
    """Load Snowflake environment variables from file if available"""
    env_file = '/tmp/snowflake_env.sh'
    if os.path.exists(env_file):
        result = subprocess.run(
            ['bash', '-c', f'source {env_file} && env'],
            capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            if '=' in line and line.startswith('SNOWFLAKE_'):
                key, _, value = line.partition('=')
                os.environ[key] = value


load_snowflake_env()


def get_private_key():
    """Load private key from base64-encoded env var"""
    import base64
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
    return p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )


def get_db_connection():
    """Create a database connection based on DB_TYPE environment variable"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        import snowflake.connector
        # Try password auth first (the eval connection uses password, not private key)
        password = os.environ.get('SNOWFLAKE_PASSWORD')
        if password:
            conn = snowflake.connector.connect(
                account=os.environ['SNOWFLAKE_ACCOUNT'],
                **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
                user=os.environ['SNOWFLAKE_USER'],
                password=password,
                database=os.environ['SNOWFLAKE_DATABASE'],
                schema='main',
                warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
                role=os.environ.get('SNOWFLAKE_ROLE', None))
            return conn, 'snowflake'
        # Fall back to private key auth
        conn = snowflake.connector.connect(
            account=os.environ['SNOWFLAKE_ACCOUNT'],
            **({'host': os.environ['SNOWFLAKE_HOST']} if os.environ.get('SNOWFLAKE_HOST') else {}),
            user=os.environ['SNOWFLAKE_USER'],
            private_key=get_private_key(),
            database=os.environ['SNOWFLAKE_DATABASE'],
            schema='main',
            warehouse=os.environ['SNOWFLAKE_WAREHOUSE'],
            role=os.environ.get('SNOWFLAKE_ROLE', None)
        )
        return conn, 'snowflake'
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        conn = duckdb.connect(db_path, read_only=True)
        return conn, 'duckdb'


def get_db_connection_rw():
    """Create a read-write database connection."""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return get_db_connection()
    else:
        import duckdb
        db_path = os.environ.get('DUCKDB_PATH', '/app/database/retail.duckdb')
        conn = duckdb.connect(db_path, read_only=False)
        return conn, 'duckdb'


def execute_query(conn, db_type, query, params=None):
    """Execute a query and return results"""
    if db_type == 'snowflake':
        cursor = conn.cursor()
        if params:
            cursor.execute(query, params)
        else:
            cursor.execute(query)
        return cursor.fetchall()
    else:
        if params:
            return conn.execute(query, params).fetchall()
        return conn.execute(query).fetchall()


def execute_scalar(conn, db_type, query, params=None):
    """Execute a query and return a single scalar value"""
    result = execute_query(conn, db_type, query, params)
    return result[0][0] if result else None


def get_dbt_project_dir():
    """Get the dbt project directory based on DB_TYPE"""
    db_type = os.environ.get('DB_TYPE', 'duckdb').lower()
    if db_type == 'snowflake':
        return os.environ.get('DBT_PROJECT_DIR_SNOWFLAKE', '/app/dbt_models_snowflake')
    else:
        return os.environ.get('DBT_PROJECT_DIR_DUCKDB', '/app/dbt_models_duckdb')


# ============ END DUAL-BACKEND INFRASTRUCTURE ============

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))


def run_cmd(cmd: str, cwd: str = None) -> subprocess.CompletedProcess:
    """
    Execute a shell command and capture output.
    """
    if cwd is None:
        cwd = "/app/dbt_transforms"
    result = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    print(f"CMD: {cmd}")
    if result.stdout:
        print(f"STDOUT: {result.stdout[:2000]}")
    if result.stderr:
        print(f"STDERR: {result.stderr[:500]}")
    return result


def require(condition: bool, msg: str) -> None:
    """
    Assert a condition is true, raising AssertionError with message if false.
    """
    if not condition:
        raise AssertionError(msg)


def run_dbt_pipeline() -> None:
    """
    Execute the dbt pipeline to build all required models.
    Runs dbt deps first, then builds all models in correct order.
    """
    deps_result = run_cmd("dbt deps")
    require(deps_result.returncode == 0, f"dbt deps failed: {deps_result.stderr}")

    # Run staging models first
    result = run_cmd(
        "dbt run --select "
        "stg_finance__currency_exchange_rates "
        "stg_procurement__purchase_orders "
        "stg_procurement__purchase_order_lines "
        "stg_orders__orders "
        "stg_orders__order_lines"
    )
    require(result.returncode == 0, f"dbt run (staging) failed: {result.stderr}")

    # Run intermediate models - these are specific to this task
    result = run_cmd(
        "dbt run --select "
        "int_finance__exchange_rates_daily "
        "int_procurement__purchases_enriched "
        "int_orders__sales_enriched"
    )
    require(result.returncode == 0, f"dbt run (intermediate) failed: {result.stderr}")

    # Run mart models
    result = run_cmd(
        "dbt run --select "
        "purchase_costs_usd "
        "sale_cogs "
        "inventory_turnover_metrics"
    )
    require(result.returncode == 0, f"dbt run (marts) failed: {result.stderr}")


def validate_table_exists(conn, db_type, table_name: str) -> None:
    """
    Validate that a table exists in the database.
    """
    result = execute_scalar(conn, db_type, f"""
        SELECT COUNT(*) FROM information_schema.tables
        WHERE lower(table_schema) = 'main' AND lower(table_name) = lower('{table_name}')
    """)
    require(int(result) == 1, f"Table '{table_name}' does not exist in database")


def validate_purchase_costs_schema(conn, db_type) -> None:
    """
    Validate that purchase_costs_usd table has all required columns with correct case.
    """
    cols = execute_query(conn, db_type, """
        SELECT column_name FROM information_schema.columns
        WHERE lower(table_schema) = 'main' AND lower(table_name) = 'purchase_costs_usd'
    """)
    col_names = {c[0] for c in cols}
    col_names_lower = {c[0].lower() for c in cols}

    required = {
        'purchase_id', 'sku', 'quantity', 'original_currency',
        'original_unit_cost', 'purchase_date', 'exchange_rate',
        'unit_cost_usd', 'total_cost_usd'
    }

    missing = required - col_names_lower
    require(not missing, f"purchase_costs_usd missing required columns: {missing}")

    # Verify lowercase naming convention
    for col in required:
        require(col in col_names or col.lower() in col_names_lower,
                f"Column '{col}' must be lowercase in purchase_costs_usd")

    print("purchase_costs_usd schema validated")


def validate_sale_cogs_schema(conn, db_type) -> None:
    """
    Validate that sale_cogs table has all required columns including new fields.
    """
    cols = execute_query(conn, db_type, """
        SELECT column_name FROM information_schema.columns
        WHERE lower(table_schema) = 'main' AND lower(table_name) = 'sale_cogs'
    """)
    col_names_lower = {c[0].lower() for c in cols}

    required = {
        'sale_id', 'order_id', 'sku', 'sale_date', 'quantity_sold',
        'cogs_usd', 'avg_unit_cost', 'batches_consumed', 'inventory_shortfall',
        'fallback_cost_usd', 'total_estimated_cogs', 'costing_method'
    }
    missing = required - col_names_lower
    require(not missing, f"sale_cogs missing required columns: {missing}")

    print("sale_cogs schema validated")


def validate_inventory_turnover_schema(conn, db_type) -> None:
    """
    Validate that inventory_turnover_metrics table has all required columns.
    """
    cols = execute_query(conn, db_type, """
        SELECT column_name FROM information_schema.columns
        WHERE lower(table_schema) = 'main' AND lower(table_name) = 'inventory_turnover_metrics'
    """)
    col_names_lower = {c[0].lower() for c in cols}

    required = {
        'sku', 'total_purchased_qty', 'total_purchased_cost_usd',
        'total_sold_qty', 'total_cogs_usd', 'remaining_inventory_qty',
        'remaining_inventory_cost_usd', 'weighted_avg_purchase_cost',
        'weighted_avg_sale_cost', 'inventory_turnover_ratio', 'gross_margin_pct'
    }
    missing = required - col_names_lower
    require(not missing, f"inventory_turnover_metrics missing required columns: {missing}")

    print("inventory_turnover_metrics schema validated")


def validate_intermediate_models_exist(conn, db_type) -> None:
    """
    Validate that required intermediate models were created.
    """
    required_intermediate = [
        'int_finance__exchange_rates_daily',
        'int_procurement__purchases_enriched',
        'int_orders__sales_enriched'
    ]

    for model_name in required_intermediate:
        result = execute_scalar(conn, db_type, f"""
            SELECT COUNT(*) FROM information_schema.tables
            WHERE lower(table_schema) = 'main'
            AND lower(table_name) = lower('{model_name}')
        """)
        require(int(result) >= 1, f"Required intermediate model '{model_name}' not found")

    print("All required intermediate models exist")


def load_source_data_snapshot(conn, db_type) -> Dict[str, Any]:
    """
    Load a snapshot of source data from staging tables for independent validation.
    This ensures we validate against the actual source data, not the agent's transformations.
    """
    snapshot = {}

    # Load exchange rates
    snapshot['exchange_rates'] = execute_query(conn, db_type, """
        SELECT effective_date, from_currency, to_currency, exchange_rate
        FROM main.stg_finance__currency_exchange_rates
        WHERE to_currency = 'USD'
        ORDER BY from_currency, effective_date
    """)

    # Load purchases with headers joined
    snapshot['purchases'] = execute_query(conn, db_type, """
        SELECT
            l.po_line_id,
            l.po_id,
            l.sku,
            l.quantity_received,
            l.unit_price,
            h.currency_code,
            CAST(h.ordered_at AS DATE) AS purchase_date
        FROM main.stg_procurement__purchase_order_lines l
        INNER JOIN main.stg_procurement__purchase_orders h ON l.po_id = h.po_id
        WHERE l.sku IS NOT NULL
          AND l.quantity_received IS NOT NULL
          AND l.quantity_received > 0
          AND l.unit_price IS NOT NULL
          AND l.unit_price > 0
        ORDER BY h.ordered_at, l.po_line_id
    """)

    # Load sales with headers joined
    snapshot['sales'] = execute_query(conn, db_type, """
        SELECT
            l.order_line_id,
            l.order_id,
            l.sku,
            l.quantity_ordered,
            CAST(h.ordered_at AS DATE) AS sale_date
        FROM main.stg_orders__order_lines l
        INNER JOIN main.stg_orders__orders h ON l.order_id = h.order_id
        WHERE l.sku IS NOT NULL
          AND l.quantity_ordered IS NOT NULL
          AND l.quantity_ordered > 0
        ORDER BY h.ordered_at, l.order_line_id
    """)

    return snapshot


def compute_expected_purchase_costs(snapshot: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Compute expected purchase costs from source data snapshot.
    This independently calculates what the purchase_costs_usd table should contain.
    """
    # Build exchange rate lookup: (currency, date) -> rate
    # For each currency, we need the most recent rate on or before a given date
    rates_by_currency = {}
    for rate_date, from_curr, to_curr, rate in snapshot['exchange_rates']:
        if from_curr not in rates_by_currency:
            rates_by_currency[from_curr] = []
        rates_by_currency[from_curr].append((str(rate_date), float(rate)))

    # Sort rates by date for each currency
    for curr in rates_by_currency:
        rates_by_currency[curr].sort(key=lambda x: x[0])

    def get_exchange_rate(currency: str, purchase_date: str) -> Optional[float]:
        """Get most recent exchange rate on or before purchase_date."""
        if currency == 'USD':
            return 1.0
        if currency not in rates_by_currency:
            return None

        best_rate = None
        for rate_date, rate in rates_by_currency[currency]:
            if rate_date <= purchase_date:
                best_rate = rate
            else:
                break
        return best_rate

    expected = []
    for purchase in snapshot['purchases']:
        po_line_id, po_id, sku, qty_received, unit_price, currency, purchase_date = purchase
        purchase_date_str = str(purchase_date)

        rate = get_exchange_rate(currency, purchase_date_str)
        if rate is None:
            continue  # Exclude purchases without available exchange rate

        unit_cost_usd = round(float(unit_price) * rate, 4)
        total_cost_usd = round(unit_cost_usd * int(qty_received), 2)

        expected.append({
            'purchase_id': str(po_line_id),
            'sku': str(sku),
            'quantity': int(qty_received),
            'original_currency': str(currency),
            'original_unit_cost': float(unit_price),
            'purchase_date': purchase_date_str,
            'exchange_rate': round(rate, 6),
            'unit_cost_usd': unit_cost_usd,
            'total_cost_usd': total_cost_usd
        })

    return expected


def compute_expected_sale_cogs(snapshot: Dict[str, Any],
                               expected_purchases: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Compute expected LIFO COGS with weighted-average fallback from source data.
    Uses periodic LIFO methodology - pools all purchases and matches to sales.
    """
    # Build inventory per SKU from expected purchases
    # Sorted LIFO - newest first (by date DESC, then ID DESC)
    inventory = {}
    sku_totals = {}  # For weighted average calculation

    for p in expected_purchases:
        sku = p['sku']
        if sku not in inventory:
            inventory[sku] = []
            sku_totals[sku] = {'total_qty': 0, 'total_cost': 0.0}

        inventory[sku].append({
            'purchase_id': p['purchase_id'],
            'quantity': p['quantity'],
            'unit_cost_usd': p['unit_cost_usd'],
            'purchase_date': p['purchase_date'],
            'remaining': p['quantity']
        })
        sku_totals[sku]['total_qty'] += p['quantity']
        sku_totals[sku]['total_cost'] += p['total_cost_usd']

    # Sort inventory by purchase_date DESC, purchase_id DESC for LIFO
    for sku in inventory:
        inventory[sku].sort(key=lambda x: (x['purchase_date'], x['purchase_id']), reverse=True)

    # Calculate weighted average cost per SKU for fallback
    weighted_avg_cost = {}
    for sku, totals in sku_totals.items():
        if totals['total_qty'] > 0:
            weighted_avg_cost[sku] = totals['total_cost'] / totals['total_qty']
        else:
            weighted_avg_cost[sku] = 0.0

    # Process sales in chronological order (date, then sale_id)
    sales = sorted(snapshot['sales'], key=lambda x: (str(x[4]), str(x[0])))

    expected_cogs = []
    for sale in sales:
        sale_id, order_id, sku, qty_sold, sale_date = sale
        sale_id_str = str(sale_id)
        order_id_str = str(order_id)
        sku_str = str(sku)
        qty_sold_int = int(qty_sold)
        sale_date_str = str(sale_date)

        qty_needed = qty_sold_int
        total_cost = 0.0
        batches_used = 0

        # Consume from LIFO inventory (newest first)
        if sku_str in inventory:
            for batch in inventory[sku_str]:
                if qty_needed <= 0:
                    break
                if batch['remaining'] <= 0:
                    continue

                consume = min(qty_needed, batch['remaining'])
                total_cost += consume * batch['unit_cost_usd']
                batch['remaining'] -= consume
                qty_needed -= consume
                batches_used += 1

        qty_fulfilled = qty_sold_int - qty_needed
        shortfall = qty_needed

        # Calculate fallback cost for shortfall using weighted average
        fallback_cost = 0.0
        if shortfall > 0 and sku_str in weighted_avg_cost:
            fallback_cost = round(shortfall * weighted_avg_cost[sku_str], 2)

        # Determine costing method
        if shortfall == 0:
            costing_method = 'LIFO_FULL'
        elif batches_used > 0:
            costing_method = 'LIFO_PARTIAL'
        else:
            costing_method = 'LIFO_NONE'

        cogs_usd = round(total_cost, 2)
        avg_unit_cost = round(total_cost / qty_fulfilled, 4) if qty_fulfilled > 0 else 0.0
        total_estimated_cogs = round(cogs_usd + fallback_cost, 2)

        expected_cogs.append({
            'sale_id': sale_id_str,
            'order_id': order_id_str,
            'sku': sku_str,
            'sale_date': sale_date_str,
            'quantity_sold': qty_sold_int,
            'cogs_usd': cogs_usd,
            'avg_unit_cost': avg_unit_cost,
            'batches_consumed': batches_used,
            'inventory_shortfall': shortfall,
            'fallback_cost_usd': fallback_cost,
            'total_estimated_cogs': total_estimated_cogs,
            'costing_method': costing_method
        })

    return expected_cogs


def compute_expected_inventory_turnover(expected_purchases: List[Dict[str, Any]],
                                        expected_cogs: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Compute expected inventory turnover metrics from computed purchases and COGS.
    """
    # Aggregate by SKU
    sku_data = {}

    # Process purchases - keep track of batches for remaining inventory calculation
    sku_purchase_batches = {}
    for p in expected_purchases:
        sku = p['sku']
        if sku not in sku_data:
            sku_data[sku] = {
                'total_purchased_qty': 0,
                'total_purchased_cost_usd': 0.0,
                'total_sold_qty': 0,
                'total_cogs_usd': 0.0
            }
            sku_purchase_batches[sku] = []

        sku_data[sku]['total_purchased_qty'] += p['quantity']
        sku_data[sku]['total_purchased_cost_usd'] += p['total_cost_usd']
        sku_purchase_batches[sku].append({
            'quantity': p['quantity'],
            'unit_cost_usd': p['unit_cost_usd'],
            'purchase_date': p['purchase_date'],
            'purchase_id': p['purchase_id']
        })

    # Process sales
    for s in expected_cogs:
        sku = s['sku']
        if sku not in sku_data:
            sku_data[sku] = {
                'total_purchased_qty': 0,
                'total_purchased_cost_usd': 0.0,
                'total_sold_qty': 0,
                'total_cogs_usd': 0.0
            }
            sku_purchase_batches[sku] = []

        sku_data[sku]['total_sold_qty'] += s['quantity_sold']
        sku_data[sku]['total_cogs_usd'] += s['cogs_usd']

    # Calculate remaining inventory and its cost
    expected_metrics = []
    for sku, data in sku_data.items():
        remaining_qty = data['total_purchased_qty'] - (data['total_sold_qty'] -
            sum(s['inventory_shortfall'] for s in expected_cogs if s['sku'] == sku))

        # Calculate remaining inventory cost using FIFO (oldest batches remain after LIFO consumption)
        remaining_cost = 0.0
        if remaining_qty > 0 and sku in sku_purchase_batches:
            # Sort batches FIFO (oldest first) for remaining inventory valuation
            batches_fifo = sorted(sku_purchase_batches[sku],
                                  key=lambda x: (x['purchase_date'], x['purchase_id']))
            qty_to_value = remaining_qty
            for batch in batches_fifo:
                if qty_to_value <= 0:
                    break
                use_qty = min(qty_to_value, batch['quantity'])
                remaining_cost += use_qty * batch['unit_cost_usd']
                qty_to_value -= use_qty

        remaining_cost = round(remaining_cost, 2) if remaining_qty > 0 else 0.0

        # Weighted averages
        weighted_avg_purchase = (round(data['total_purchased_cost_usd'] / data['total_purchased_qty'], 4)
                                if data['total_purchased_qty'] > 0 else 0.0)

        fulfilled_qty_total = sum(s['quantity_sold'] - s['inventory_shortfall']
                                  for s in expected_cogs if s['sku'] == sku)
        weighted_avg_sale = (round(data['total_cogs_usd'] / fulfilled_qty_total, 4)
                            if fulfilled_qty_total > 0 else 0.0)

        # Inventory turnover ratio: COGS / Average Inventory
        # Assuming beginning inventory = 0, average = ending / 2
        avg_inventory_cost = remaining_cost / 2 if remaining_cost > 0 else None
        turnover_ratio = (round(data['total_cogs_usd'] / avg_inventory_cost, 4)
                         if avg_inventory_cost and avg_inventory_cost > 0 else None)

        expected_metrics.append({
            'sku': sku,
            'total_purchased_qty': data['total_purchased_qty'],
            'total_purchased_cost_usd': round(data['total_purchased_cost_usd'], 2),
            'total_sold_qty': data['total_sold_qty'],
            'total_cogs_usd': round(data['total_cogs_usd'], 2),
            'remaining_inventory_qty': remaining_qty,
            'remaining_inventory_cost_usd': remaining_cost,
            'weighted_avg_purchase_cost': weighted_avg_purchase,
            'weighted_avg_sale_cost': weighted_avg_sale,
            'inventory_turnover_ratio': turnover_ratio,
            'gross_margin_pct': None  # No standard sale price available
        })

    return expected_metrics


def validate_purchase_costs_data(conn, db_type,
                                  expected: List[Dict[str, Any]]) -> None:
    """
    Validate purchase_costs_usd data against expected values.
    """
    actual = execute_query(conn, db_type, """
        SELECT
            purchase_id,
            sku,
            quantity,
            original_currency,
            original_unit_cost,
            purchase_date,
            exchange_rate,
            unit_cost_usd,
            total_cost_usd
        FROM main.purchase_costs_usd
        ORDER BY purchase_id
    """)

    actual_by_id = {str(r[0]): r for r in actual}

    # Validate row count
    require(
        len(actual) == len(expected),
        f"purchase_costs_usd row count mismatch: expected {len(expected)}, got {len(actual)}"
    )

    errors = []
    for exp in expected:
        purchase_id = exp['purchase_id']

        if purchase_id not in actual_by_id:
            errors.append(f"Missing purchase_id: {purchase_id}")
            continue

        act = actual_by_id[purchase_id]

        # Validate SKU
        if str(act[1]) != exp['sku']:
            errors.append(f"Purchase {purchase_id}: sku mismatch - expected {exp['sku']}, got {act[1]}")

        # Validate quantity
        if int(act[2]) != exp['quantity']:
            errors.append(f"Purchase {purchase_id}: quantity mismatch - expected {exp['quantity']}, got {act[2]}")

        # Validate exchange rate (6 decimal precision)
        act_rate = float(act[6])
        exp_rate = exp['exchange_rate']
        if abs(act_rate - exp_rate) >= 0.000001:
            errors.append(f"Purchase {purchase_id}: exchange_rate mismatch - expected {exp_rate:.6f}, got {act_rate:.6f}")

        # Validate unit_cost_usd (4 decimal precision)
        act_unit = float(act[7])
        exp_unit = exp['unit_cost_usd']
        if abs(act_unit - exp_unit) >= 0.0001:
            errors.append(f"Purchase {purchase_id}: unit_cost_usd mismatch - expected {exp_unit:.4f}, got {act_unit:.4f}")

        # Validate total_cost_usd (2 decimal precision)
        act_total = float(act[8])
        exp_total = exp['total_cost_usd']
        if abs(act_total - exp_total) >= 0.01:
            errors.append(f"Purchase {purchase_id}: total_cost_usd mismatch - expected {exp_total:.2f}, got {act_total:.2f}")

    require(len(errors) == 0, f"purchase_costs_usd validation errors:\n" + "\n".join(errors[:10]))
    print(f"Validated {len(expected)} purchase cost records")


def validate_sale_cogs_data(conn, db_type,
                            expected: List[Dict[str, Any]]) -> None:
    """
    Validate sale_cogs data against expected LIFO calculations including new fields.
    """
    actual = execute_query(conn, db_type, """
        SELECT
            sale_id,
            order_id,
            sku,
            sale_date,
            quantity_sold,
            cogs_usd,
            avg_unit_cost,
            batches_consumed,
            inventory_shortfall,
            fallback_cost_usd,
            total_estimated_cogs,
            costing_method
        FROM main.sale_cogs
        ORDER BY sale_id
    """)

    actual_by_id = {str(r[0]): r for r in actual}

    # Validate row count
    require(
        len(actual) == len(expected),
        f"sale_cogs row count mismatch: expected {len(expected)}, got {len(actual)}"
    )

    errors = []
    for exp in expected:
        sale_id = exp['sale_id']

        if sale_id not in actual_by_id:
            errors.append(f"Missing sale_id: {sale_id}")
            continue

        act = actual_by_id[sale_id]

        # Validate order_id
        if str(act[1]) != exp['order_id']:
            errors.append(f"Sale {sale_id}: order_id mismatch - expected {exp['order_id']}, got {act[1]}")

        # Validate SKU
        if str(act[2]) != exp['sku']:
            errors.append(f"Sale {sale_id}: sku mismatch - expected {exp['sku']}, got {act[2]}")

        # Validate quantity_sold
        if int(act[4]) != exp['quantity_sold']:
            errors.append(f"Sale {sale_id}: quantity_sold mismatch - expected {exp['quantity_sold']}, got {act[4]}")

        # Validate cogs_usd (2 decimal precision)
        act_cogs = float(act[5])
        exp_cogs = exp['cogs_usd']
        if abs(act_cogs - exp_cogs) >= 0.01:
            errors.append(f"Sale {sale_id}: cogs_usd mismatch - expected {exp_cogs:.2f}, got {act_cogs:.2f}")

        # Validate avg_unit_cost (4 decimal precision)
        act_avg = float(act[6])
        exp_avg = exp['avg_unit_cost']
        if abs(act_avg - exp_avg) >= 0.0001:
            errors.append(f"Sale {sale_id}: avg_unit_cost mismatch - expected {exp_avg:.4f}, got {act_avg:.4f}")

        # Validate batches_consumed
        if int(act[7]) != exp['batches_consumed']:
            errors.append(f"Sale {sale_id}: batches_consumed mismatch - expected {exp['batches_consumed']}, got {act[7]}")

        # Validate inventory_shortfall
        if int(act[8]) != exp['inventory_shortfall']:
            errors.append(f"Sale {sale_id}: inventory_shortfall mismatch - expected {exp['inventory_shortfall']}, got {act[8]}")

        # Validate fallback_cost_usd (2 decimal precision)
        act_fallback = float(act[9]) if act[9] is not None else 0.0
        exp_fallback = exp['fallback_cost_usd']
        if abs(act_fallback - exp_fallback) >= 0.01:
            errors.append(f"Sale {sale_id}: fallback_cost_usd mismatch - expected {exp_fallback:.2f}, got {act_fallback:.2f}")

        # Validate total_estimated_cogs (2 decimal precision)
        act_total_est = float(act[10]) if act[10] is not None else 0.0
        exp_total_est = exp['total_estimated_cogs']
        if abs(act_total_est - exp_total_est) >= 0.01:
            errors.append(f"Sale {sale_id}: total_estimated_cogs mismatch - expected {exp_total_est:.2f}, got {act_total_est:.2f}")

        # Validate costing_method
        act_method = str(act[11]) if act[11] is not None else ''
        exp_method = exp['costing_method']
        if act_method != exp_method:
            errors.append(f"Sale {sale_id}: costing_method mismatch - expected {exp_method}, got {act_method}")

    require(len(errors) == 0, f"sale_cogs validation errors:\n" + "\n".join(errors[:10]))
    print(f"Validated {len(expected)} sale COGS records")


def validate_inventory_turnover_data(conn, db_type,
                                     expected: List[Dict[str, Any]]) -> None:
    """
    Validate inventory_turnover_metrics data against expected calculations.
    """
    actual = execute_query(conn, db_type, """
        SELECT
            sku,
            total_purchased_qty,
            total_purchased_cost_usd,
            total_sold_qty,
            total_cogs_usd,
            remaining_inventory_qty,
            remaining_inventory_cost_usd,
            weighted_avg_purchase_cost,
            weighted_avg_sale_cost,
            inventory_turnover_ratio,
            gross_margin_pct
        FROM main.inventory_turnover_metrics
        ORDER BY sku
    """)

    actual_by_sku = {str(r[0]): r for r in actual}

    errors = []
    for exp in expected:
        sku = exp['sku']

        if sku not in actual_by_sku:
            errors.append(f"Missing SKU in inventory_turnover_metrics: {sku}")
            continue

        act = actual_by_sku[sku]

        # Validate quantities
        if int(act[1]) != exp['total_purchased_qty']:
            errors.append(f"SKU {sku}: total_purchased_qty mismatch - expected {exp['total_purchased_qty']}, got {act[1]}")

        # Validate total_purchased_cost_usd
        if abs(float(act[2]) - exp['total_purchased_cost_usd']) >= 0.01:
            errors.append(f"SKU {sku}: total_purchased_cost_usd mismatch - expected {exp['total_purchased_cost_usd']:.2f}, got {float(act[2]):.2f}")

        if int(act[3]) != exp['total_sold_qty']:
            errors.append(f"SKU {sku}: total_sold_qty mismatch - expected {exp['total_sold_qty']}, got {act[3]}")

        # Validate total_cogs_usd
        if abs(float(act[4]) - exp['total_cogs_usd']) >= 0.01:
            errors.append(f"SKU {sku}: total_cogs_usd mismatch - expected {exp['total_cogs_usd']:.2f}, got {float(act[4]):.2f}")

        # Validate remaining_inventory_qty (can be negative)
        if int(act[5]) != exp['remaining_inventory_qty']:
            errors.append(f"SKU {sku}: remaining_inventory_qty mismatch - expected {exp['remaining_inventory_qty']}, got {act[5]}")

        # Validate weighted averages (4 decimal precision)
        if abs(float(act[7]) - exp['weighted_avg_purchase_cost']) >= 0.0001:
            errors.append(f"SKU {sku}: weighted_avg_purchase_cost mismatch - expected {exp['weighted_avg_purchase_cost']:.4f}, got {float(act[7]):.4f}")

        if abs(float(act[8]) - exp['weighted_avg_sale_cost']) >= 0.0001:
            errors.append(f"SKU {sku}: weighted_avg_sale_cost mismatch - expected {exp['weighted_avg_sale_cost']:.4f}, got {float(act[8]):.4f}")

    require(len(errors) == 0, f"inventory_turnover_metrics validation errors:\n" + "\n".join(errors[:10]))
    print(f"Validated {len(expected)} inventory turnover metric records")


def validate_usd_purchases_have_rate_one(conn, db_type) -> None:
    """
    Validate that USD currency purchases have exchange_rate = 1.0.
    """
    violations = execute_query(conn, db_type, """
        SELECT purchase_id, exchange_rate
        FROM main.purchase_costs_usd
        WHERE original_currency = 'USD'
        AND ABS(exchange_rate - 1.0) > 0.000001
    """)

    require(len(violations) == 0,
            f"USD purchases with incorrect exchange_rate (should be 1.0): {violations[:5]}")

    print("USD purchases correctly have exchange_rate = 1.0")


def validate_cost_calculations(conn, db_type) -> None:
    """
    Validate that cost calculations are mathematically correct.
    """
    violations = execute_query(conn, db_type, """
        SELECT
            purchase_id,
            original_unit_cost,
            exchange_rate,
            unit_cost_usd,
            quantity,
            total_cost_usd
        FROM main.purchase_costs_usd
        WHERE ABS(unit_cost_usd - ROUND(CAST(original_unit_cost AS DOUBLE) * exchange_rate, 4)) > 0.0001
           OR ABS(total_cost_usd - ROUND(unit_cost_usd * quantity, 2)) > 0.01
        LIMIT 5
    """)

    require(len(violations) == 0,
            f"Cost calculation errors found: {violations}")

    print("Cost calculations are mathematically correct")


def validate_no_null_values(conn, db_type) -> None:
    """
    Validate that output tables don't contain NULL values in required columns.
    """
    null_check = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM main.purchase_costs_usd
        WHERE purchase_id IS NULL OR sku IS NULL OR quantity IS NULL
           OR original_currency IS NULL OR exchange_rate IS NULL
           OR unit_cost_usd IS NULL OR total_cost_usd IS NULL
    """)
    require(int(null_check) == 0,
            f"purchase_costs_usd contains {null_check} rows with NULL values in required columns")

    null_check = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM main.sale_cogs
        WHERE sale_id IS NULL OR order_id IS NULL OR sku IS NULL
           OR quantity_sold IS NULL OR cogs_usd IS NULL
           OR avg_unit_cost IS NULL OR batches_consumed IS NULL
           OR inventory_shortfall IS NULL OR fallback_cost_usd IS NULL
           OR total_estimated_cogs IS NULL OR costing_method IS NULL
    """)
    require(int(null_check) == 0,
            f"sale_cogs contains {null_check} rows with NULL values in required columns")

    print("No NULL values in required columns")


def validate_positive_quantities(conn, db_type) -> None:
    """
    Validate that quantities are positive integers.
    """
    invalid_purchase_qty = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM main.purchase_costs_usd
        WHERE quantity <= 0
    """)
    require(int(invalid_purchase_qty) == 0,
            f"purchase_costs_usd contains {invalid_purchase_qty} rows with non-positive quantity")

    invalid_sale_qty = execute_scalar(conn, db_type, """
        SELECT COUNT(*) FROM main.sale_cogs
        WHERE quantity_sold <= 0
    """)
    require(int(invalid_sale_qty) == 0,
            f"sale_cogs contains {invalid_sale_qty} rows with non-positive quantity_sold")

    print("All quantities are positive")


def validate_costing_method_classification(conn, db_type) -> None:
    """
    Validate that costing_method is correctly assigned based on batches_consumed and inventory_shortfall.
    """
    # LIFO_FULL: shortfall = 0
    violations = execute_query(conn, db_type, """
        SELECT sale_id, inventory_shortfall, batches_consumed, costing_method
        FROM main.sale_cogs
        WHERE inventory_shortfall = 0 AND costing_method != 'LIFO_FULL'
    """)
    require(len(violations) == 0,
            f"Sales with shortfall=0 should have costing_method='LIFO_FULL': {violations[:5]}")

    # LIFO_PARTIAL: shortfall > 0 AND batches_consumed > 0
    violations = execute_query(conn, db_type, """
        SELECT sale_id, inventory_shortfall, batches_consumed, costing_method
        FROM main.sale_cogs
        WHERE inventory_shortfall > 0 AND batches_consumed > 0 AND costing_method != 'LIFO_PARTIAL'
    """)
    require(len(violations) == 0,
            f"Sales with partial fulfillment should have costing_method='LIFO_PARTIAL': {violations[:5]}")

    # LIFO_NONE: batches_consumed = 0
    violations = execute_query(conn, db_type, """
        SELECT sale_id, inventory_shortfall, batches_consumed, costing_method
        FROM main.sale_cogs
        WHERE batches_consumed = 0 AND costing_method != 'LIFO_NONE'
    """)
    require(len(violations) == 0,
            f"Sales with batches_consumed=0 should have costing_method='LIFO_NONE': {violations[:5]}")

    print("Costing method classification validated")


def validate_fallback_cost_calculation(conn, db_type) -> None:
    """
    Validate that fallback_cost_usd is correctly calculated using weighted average.
    """
    # When shortfall = 0, fallback_cost should be 0
    violations = execute_query(conn, db_type, """
        SELECT sale_id, inventory_shortfall, fallback_cost_usd
        FROM main.sale_cogs
        WHERE inventory_shortfall = 0 AND ABS(fallback_cost_usd) > 0.001
    """)
    require(len(violations) == 0,
            f"Sales with no shortfall should have fallback_cost_usd=0: {violations[:5]}")

    # Validate total_estimated_cogs = cogs_usd + fallback_cost_usd
    violations = execute_query(conn, db_type, """
        SELECT sale_id, cogs_usd, fallback_cost_usd, total_estimated_cogs
        FROM main.sale_cogs
        WHERE ABS(total_estimated_cogs - (cogs_usd + fallback_cost_usd)) > 0.01
    """)
    require(len(violations) == 0,
            f"total_estimated_cogs should equal cogs_usd + fallback_cost_usd: {violations[:5]}")

    print("Fallback cost calculations validated")


def validate_cogs_consistency(conn, db_type) -> None:
    """
    Validate that COGS values are internally consistent.
    """
    # When no batches consumed, COGS should be 0
    violations = execute_query(conn, db_type, """
        SELECT sale_id, batches_consumed, cogs_usd
        FROM main.sale_cogs
        WHERE batches_consumed = 0 AND ABS(cogs_usd) > 0.001
    """)
    require(len(violations) == 0,
            f"Sales with batches_consumed=0 but non-zero cogs_usd: {violations[:5]}")

    # When batches_consumed=0, avg_unit_cost should be 0
    violations = execute_query(conn, db_type, """
        SELECT sale_id, batches_consumed, avg_unit_cost
        FROM main.sale_cogs
        WHERE batches_consumed = 0 AND ABS(avg_unit_cost) > 0.001
    """)
    require(len(violations) == 0,
            f"Sales with batches_consumed=0 but non-zero avg_unit_cost: {violations[:5]}")

    # When batches_consumed=0, shortfall should equal quantity
    violations = execute_query(conn, db_type, """
        SELECT sale_id, quantity_sold, batches_consumed, inventory_shortfall
        FROM main.sale_cogs
        WHERE batches_consumed = 0 AND inventory_shortfall != quantity_sold
    """)
    require(len(violations) == 0,
            f"Sales with batches_consumed=0 but incorrect inventory_shortfall: {violations[:5]}")

    print("COGS values are internally consistent")


def validate_total_inventory_balance(conn, db_type) -> None:
    """
    Validate that total inventory consumed + remaining = total purchased per SKU.
    """
    check = execute_query(conn, db_type, """
        WITH purchase_totals AS (
            SELECT sku, SUM(quantity) as total_purchased
            FROM main.purchase_costs_usd
            GROUP BY sku
        ),
        sale_totals AS (
            SELECT sku,
                   SUM(quantity_sold - inventory_shortfall) as total_consumed,
                   SUM(inventory_shortfall) as total_shortfall
            FROM main.sale_cogs
            GROUP BY sku
        )
        SELECT
            COALESCE(p.sku, s.sku) as sku,
            COALESCE(p.total_purchased, 0) as purchased,
            COALESCE(s.total_consumed, 0) as consumed,
            COALESCE(s.total_shortfall, 0) as shortfall
        FROM purchase_totals p
        FULL OUTER JOIN sale_totals s ON p.sku = s.sku
        WHERE COALESCE(s.total_consumed, 0) > COALESCE(p.total_purchased, 0)
    """)

    require(
        len(check) == 0,
        f"Inventory balance violated - consumed exceeds purchased for SKUs: {check[:5]}"
    )

    print("Total inventory balance validated")


def validate_lifo_ordering_strict(conn, db_type,
                                  expected_purchases: List[Dict[str, Any]]) -> None:
    """
    Strictly validate LIFO ordering by checking that newer purchases
    are depleted before older ones across the entire dataset.
    """
    # Get purchase batches ordered LIFO
    purchases = execute_query(conn, db_type, """
        SELECT purchase_id, sku, quantity, unit_cost_usd, purchase_date
        FROM main.purchase_costs_usd
        ORDER BY sku, purchase_date DESC, purchase_id DESC
    """)

    # Get all sales ordered chronologically
    sales = execute_query(conn, db_type, """
        SELECT sale_id, sku, quantity_sold, inventory_shortfall
        FROM main.sale_cogs
        ORDER BY sale_date, sale_id
    """)

    # Simulate LIFO consumption
    inventory = {}
    original_qty = {}
    for p in purchases:
        purchase_id, sku, qty, cost, date = p
        sku_str = str(sku)
        pid_str = str(purchase_id)
        if sku_str not in inventory:
            inventory[sku_str] = []
            original_qty[sku_str] = {}
        inventory[sku_str].append({
            'id': pid_str,
            'remaining': int(qty),
            'date': str(date)
        })
        original_qty[sku_str][pid_str] = int(qty)

    # Sort each SKU's batches LIFO (newest first)
    for sku in inventory:
        inventory[sku].sort(key=lambda x: (x['date'], x['id']), reverse=True)

    # Process sales
    for sale in sales:
        sale_id, sku, qty_sold, shortfall = sale
        sku_str = str(sku)
        qty_needed = int(qty_sold) - int(shortfall)

        if sku_str not in inventory:
            continue

        for batch in inventory[sku_str]:
            if qty_needed <= 0:
                break
            if batch['remaining'] <= 0:
                continue
            consume = min(qty_needed, batch['remaining'])
            batch['remaining'] -= consume
            qty_needed -= consume

    # Verify that if a newer batch has remaining inventory, older batches are full
    for sku, batches in inventory.items():
        found_consumed = False
        for i, batch in enumerate(batches):
            orig = original_qty[sku][batch['id']]
            if found_consumed and batch['remaining'] < orig:
                for newer in batches[:i]:
                    if newer['remaining'] > 0:
                        require(False,
                            f"LIFO violation for {sku}: Batch {batch['id']} (older) was consumed "
                            f"while batch {newer['id']} (newer) still had {newer['remaining']} remaining")
            if batch['remaining'] < orig:
                found_consumed = True

    print("Strict LIFO ordering validated")


def validate_column_types(conn, db_type) -> None:
    """
    Validate that columns have correct data types as specified in requirements.
    """
    # Check purchase_costs_usd column types
    purchase_cols = execute_query(conn, db_type, """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = 'main' AND lower(table_name) = 'purchase_costs_usd'
    """)
    purchase_types = {c[0].lower(): c[1].upper() for c in purchase_cols}

    # Quantity must be integer-like type
    qty_type = purchase_types.get('quantity', '')
    require(
        'INTEGER' in qty_type or 'INT' in qty_type or 'BIGINT' in qty_type or 'NUMBER' in qty_type or 'NUMERIC' in qty_type,
        f"purchase_costs_usd.quantity must be integer type, got: {purchase_types.get('quantity')}"
    )

    # Check sale_cogs column types
    sale_cols = execute_query(conn, db_type, """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE lower(table_schema) = 'main' AND lower(table_name) = 'sale_cogs'
    """)
    sale_types = {c[0].lower(): c[1].upper() for c in sale_cols}

    # quantity_sold, batches_consumed, inventory_shortfall must be integer-like
    for col in ['quantity_sold', 'batches_consumed', 'inventory_shortfall']:
        col_type = sale_types.get(col, '')
        require(
            'INTEGER' in col_type or 'INT' in col_type or 'BIGINT' in col_type or 'NUMBER' in col_type or 'NUMERIC' in col_type,
            f"sale_cogs.{col} must be integer type, got: {sale_types.get(col)}"
        )

    # costing_method must be string/varchar
    cm_type = sale_types.get('costing_method', '')
    require(
        'VARCHAR' in cm_type or 'CHAR' in cm_type or 'TEXT' in cm_type or 'STRING' in cm_type,
        f"sale_cogs.costing_method must be string type, got: {sale_types.get('costing_method')}"
    )

    print("Column types validated")


def validate_idempotency(conn, db_type) -> None:
    """
    Validate that running dbt run twice produces identical results.
    """
    # Get current state
    purchase_count_1 = int(execute_scalar(conn, db_type,
        "SELECT COUNT(*) FROM main.purchase_costs_usd"))
    sale_count_1 = int(execute_scalar(conn, db_type,
        "SELECT COUNT(*) FROM main.sale_cogs"))
    turnover_count_1 = int(execute_scalar(conn, db_type,
        "SELECT COUNT(*) FROM main.inventory_turnover_metrics"))
    purchase_sum_1 = float(execute_scalar(conn, db_type,
        "SELECT COALESCE(SUM(total_cost_usd), 0) FROM main.purchase_costs_usd"))
    sale_sum_1 = float(execute_scalar(conn, db_type,
        "SELECT COALESCE(SUM(cogs_usd), 0) FROM main.sale_cogs"))

    # Close connection before re-run (especially important for DuckDB)
    conn.close()

    # Run dbt again
    result = run_cmd("dbt run --select purchase_costs_usd sale_cogs inventory_turnover_metrics")
    require(result.returncode == 0, f"Second dbt run failed: {result.stderr}")

    # Re-connect and compare results
    conn2, db_type2 = get_db_connection()
    try:
        purchase_count_2 = int(execute_scalar(conn2, db_type2,
            "SELECT COUNT(*) FROM main.purchase_costs_usd"))
        sale_count_2 = int(execute_scalar(conn2, db_type2,
            "SELECT COUNT(*) FROM main.sale_cogs"))
        turnover_count_2 = int(execute_scalar(conn2, db_type2,
            "SELECT COUNT(*) FROM main.inventory_turnover_metrics"))
        purchase_sum_2 = float(execute_scalar(conn2, db_type2,
            "SELECT COALESCE(SUM(total_cost_usd), 0) FROM main.purchase_costs_usd"))
        sale_sum_2 = float(execute_scalar(conn2, db_type2,
            "SELECT COALESCE(SUM(cogs_usd), 0) FROM main.sale_cogs"))
    finally:
        conn2.close()

    require(purchase_count_1 == purchase_count_2,
            f"Idempotency failed: purchase_costs_usd row count changed from {purchase_count_1} to {purchase_count_2}")
    require(sale_count_1 == sale_count_2,
            f"Idempotency failed: sale_cogs row count changed from {sale_count_1} to {sale_count_2}")
    require(turnover_count_1 == turnover_count_2,
            f"Idempotency failed: inventory_turnover_metrics row count changed from {turnover_count_1} to {turnover_count_2}")
    require(abs(purchase_sum_1 - purchase_sum_2) < 0.01,
            f"Idempotency failed: purchase_costs_usd total changed")
    require(abs(sale_sum_1 - sale_sum_2) < 0.01,
            f"Idempotency failed: sale_cogs total changed")

    print("Idempotency validated - results identical after re-run")


def test_multicurrency_lifo():
    """
    Main test function that validates the complete multi-currency LIFO implementation.
    Tests schema, data accuracy, LIFO logic, edge cases, and idempotency.
    All checks are pass/fail (1.0 or 0.0) with no partial scoring.
    """
    print("\n" + "=" * 60)
    print("Multi-Currency LIFO Inventory Costing Validation")
    print("With Weighted-Average Fallback and Turnover Metrics")
    print("=" * 60)

    # Run dbt pipeline with original data
    run_dbt_pipeline()

    # Connect to database for initial validation
    conn, db_type = get_db_connection()

    try:
        # Phase 1: Schema validation
        print("\n--- Schema Validation ---")
        validate_table_exists(conn, db_type, 'purchase_costs_usd')
        validate_table_exists(conn, db_type, 'sale_cogs')
        validate_table_exists(conn, db_type, 'inventory_turnover_metrics')
        validate_purchase_costs_schema(conn, db_type)
        validate_sale_cogs_schema(conn, db_type)
        validate_inventory_turnover_schema(conn, db_type)
        validate_intermediate_models_exist(conn, db_type)
        validate_column_types(conn, db_type)

        # Phase 2: Data quality checks
        print("\n--- Data Quality Checks ---")
        validate_no_null_values(conn, db_type)
        validate_positive_quantities(conn, db_type)
        validate_usd_purchases_have_rate_one(conn, db_type)
        validate_cost_calculations(conn, db_type)
        validate_cogs_consistency(conn, db_type)
        validate_costing_method_classification(conn, db_type)
        validate_fallback_cost_calculation(conn, db_type)
        validate_total_inventory_balance(conn, db_type)

        # Phase 3: Load source data snapshot for independent validation
        print("\n--- Loading Source Data Snapshot ---")
        snapshot = load_source_data_snapshot(conn, db_type)
        print(f"Loaded {len(snapshot['purchases'])} purchases, {len(snapshot['sales'])} sales, {len(snapshot['exchange_rates'])} exchange rates")

        # Phase 4: Compute expected values from source data
        print("\n--- Computing Expected Values ---")
        expected_purchases = compute_expected_purchase_costs(snapshot)
        print(f"Computed {len(expected_purchases)} expected purchase costs")
        expected_sales = compute_expected_sale_cogs(snapshot, expected_purchases)
        print(f"Computed {len(expected_sales)} expected sale COGS records")
        expected_turnover = compute_expected_inventory_turnover(expected_purchases, expected_sales)
        print(f"Computed {len(expected_turnover)} expected inventory turnover metrics")

        # Phase 5: Data accuracy validation
        print("\n--- Data Accuracy Validation ---")
        validate_purchase_costs_data(conn, db_type, expected_purchases)
        validate_sale_cogs_data(conn, db_type, expected_sales)
        validate_inventory_turnover_data(conn, db_type, expected_turnover)

        # Phase 6: Strict LIFO ordering validation
        print("\n--- LIFO Ordering Validation ---")
        validate_lifo_ordering_strict(conn, db_type, expected_purchases)

    finally:
        conn.close()

    # Phase 7: Idempotency check (needs fresh connections)
    print("\n--- Idempotency Check ---")
    conn3, db_type3 = get_db_connection()
    validate_idempotency(conn3, db_type3)

    print("\n" + "=" * 60)
    print("ALL VALIDATION CHECKS PASSED!")
    print("=" * 60)


if __name__ == "__main__":
    import sys
    try:
        test_multicurrency_lifo()
        sys.exit(0)
    except AssertionError as e:
        print(f"\nVALIDATION FAILED: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\nERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
