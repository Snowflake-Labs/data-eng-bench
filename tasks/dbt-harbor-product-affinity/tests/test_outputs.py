import os
import subprocess
import pytest


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


# Load Snowflake env vars at module import time
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
        private_key_pem,
        password=passphrase_bytes,
        backend=default_backend()
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
                host=os.environ.get('SNOWFLAKE_HOST') or None,
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
            host=os.environ.get('SNOWFLAKE_HOST') or None,
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


# ============ FIXTURES ============


@pytest.fixture(scope="session")
def db():
    """Create database connection"""
    conn, db_type = get_db_connection()
    yield conn, db_type
    conn.close()


# ============ TESTS ============


def test_staging_model_exists(db):
    """Test that stg_basket__order_products model exists"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*) as cnt
        FROM information_schema.tables
        WHERE lower(table_schema) = 'main_staging'
        AND lower(table_name) = 'stg_basket__order_products'
    """)
    assert int(result) == 1, "stg_basket__order_products model does not exist"


def test_staging_model_columns(db):
    """Test that staging model has required columns"""
    conn, db_type = db
    required_columns = {
        'order_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_name': ['VARCHAR', 'TEXT'],
        'category_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'category_name': ['VARCHAR', 'TEXT']
    }

    columns = execute_query(conn, db_type, """
        SELECT lower(column_name), upper(data_type)
        FROM information_schema.columns
        WHERE lower(table_schema) = 'main_staging'
        AND lower(table_name) = 'stg_basket__order_products'
    """)

    column_dict = {col[0]: col[1] for col in columns}

    for col_name, accepted_types in required_columns.items():
        assert col_name.lower() in column_dict, f"Missing column: {col_name}"
        actual_type = column_dict[col_name.lower()]
        assert actual_type in accepted_types, f"Wrong type for {col_name}: expected one of {accepted_types}, got {actual_type}"


def test_staging_model_has_data(db):
    """Test that staging model has data"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, "SELECT COUNT(*) FROM main_staging.stg_basket__order_products")
    assert int(result) > 0, "Staging model is empty"


def test_product_pairs_model_exists(db):
    """Test that int_affinity__product_pairs model exists"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*) as cnt
        FROM information_schema.tables
        WHERE lower(table_schema) = 'main_intermediate'
        AND lower(table_name) = 'int_affinity__product_pairs'
    """)
    assert int(result) == 1, "int_affinity__product_pairs model does not exist"


def test_product_pairs_columns(db):
    """Test that product pairs model has required columns"""
    conn, db_type = db
    required_columns = {
        'order_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_a_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_a_name': ['VARCHAR', 'TEXT'],
        'product_b_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_b_name': ['VARCHAR', 'TEXT'],
        'category_a_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'category_b_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT']
    }

    columns = execute_query(conn, db_type, """
        SELECT lower(column_name), upper(data_type)
        FROM information_schema.columns
        WHERE lower(table_schema) = 'main_intermediate'
        AND lower(table_name) = 'int_affinity__product_pairs'
    """)

    column_dict = {col[0]: col[1] for col in columns}

    for col_name, accepted_types in required_columns.items():
        assert col_name.lower() in column_dict, f"Missing column: {col_name}"
        actual_type = column_dict[col_name.lower()]
        assert actual_type in accepted_types, f"Wrong type for {col_name}: expected one of {accepted_types}, got {actual_type}"


def test_product_pairs_no_duplicates(db):
    """Test that product pairs have no duplicates (product_a_id < product_b_id)"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main_intermediate.int_affinity__product_pairs
        WHERE product_a_id >= product_b_id
    """)
    assert int(result) == 0, "Product pairs contain invalid pairs where product_a_id >= product_b_id"


def test_product_pairs_per_order_pair_count(db):
    """Test that each order has exactly N*(N-1)/2 pairs based on distinct products"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        WITH order_products AS (
            SELECT
                order_id,
                product_id
            FROM main_staging.stg_basket__order_products
            GROUP BY order_id, product_id
        ),
        order_counts AS (
            SELECT
                order_id,
                COUNT(*) AS product_count
            FROM order_products
            GROUP BY order_id
        ),
        expected_pairs AS (
            SELECT
                order_id,
                (product_count * (product_count - 1)) / 2 AS expected_pair_count
            FROM order_counts
        ),
        actual_pairs AS (
            SELECT
                order_id,
                COUNT(*) AS actual_pair_count
            FROM main_intermediate.int_affinity__product_pairs
            GROUP BY order_id
        )
        SELECT COUNT(*)
        FROM expected_pairs e
        LEFT JOIN actual_pairs a ON e.order_id = a.order_id
        WHERE COALESCE(a.actual_pair_count, 0) != e.expected_pair_count
    """)
    assert int(result) == 0, "Per-order pair counts do not match N*(N-1)/2 based on distinct products"


def test_association_rules_model_exists(db):
    """Test that int_affinity__association_rules model exists"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*) as cnt
        FROM information_schema.tables
        WHERE lower(table_schema) = 'main_intermediate'
        AND lower(table_name) = 'int_affinity__association_rules'
    """)
    assert int(result) == 1, "int_affinity__association_rules model does not exist"


def test_association_rules_columns(db):
    """Test that association rules model has required columns"""
    conn, db_type = db
    required_columns = {
        'product_a_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_a_name': ['VARCHAR', 'TEXT'],
        'product_b_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_b_name': ['VARCHAR', 'TEXT'],
        'support': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'confidence': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'lift': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'conviction': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'orders_with_both': ['INTEGER', 'BIGINT', 'NUMBER'],
        'orders_with_a': ['INTEGER', 'BIGINT', 'NUMBER'],
        'orders_with_b': ['INTEGER', 'BIGINT', 'NUMBER'],
        'total_orders': ['INTEGER', 'BIGINT', 'NUMBER']
    }

    columns = execute_query(conn, db_type, """
        SELECT lower(column_name), upper(data_type)
        FROM information_schema.columns
        WHERE lower(table_schema) = 'main_intermediate'
        AND lower(table_name) = 'int_affinity__association_rules'
    """)

    column_dict = {col[0]: col[1] for col in columns}

    for col_name, accepted_types in required_columns.items():
        assert col_name.lower() in column_dict, f"Missing column: {col_name}"
        actual_type = column_dict[col_name.lower()]
        assert actual_type in accepted_types, f"Wrong type for {col_name}: expected one of {accepted_types}, got {actual_type}"


def test_association_rules_metrics_valid_range(db):
    """Test that support and confidence are between 0 and 1"""
    conn, db_type = db
    result = execute_query(conn, db_type, """
        SELECT
            COUNT(*) as total,
            SUM(CASE WHEN support < 0 OR support > 1 THEN 1 ELSE 0 END) as invalid_support,
            SUM(CASE WHEN confidence < 0 OR confidence > 1 THEN 1 ELSE 0 END) as invalid_confidence
        FROM main_intermediate.int_affinity__association_rules
    """)

    assert int(result[0][1]) == 0, f"Found {result[0][1]} rows with invalid support values (not between 0 and 1)"
    assert int(result[0][2]) == 0, f"Found {result[0][2]} rows with invalid confidence values (not between 0 and 1)"


def test_association_rules_no_self_pairs(db):
    """Test that association rules do not include self-pairs"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main_intermediate.int_affinity__association_rules
        WHERE product_a_id = product_b_id
    """)
    assert int(result) == 0, "Association rules contain self-pairs"


def test_association_rules_no_duplicate_pairs(db):
    """Test that association rules have no duplicate directional rows"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM (
            SELECT product_a_id, product_b_id, COUNT(*) AS cnt
            FROM main_intermediate.int_affinity__association_rules
            GROUP BY product_a_id, product_b_id
            HAVING COUNT(*) > 1
        ) dups
    """)
    assert int(result) == 0, "Association rules contain duplicate directional pairs"


def test_association_rules_directional_pairs(db):
    """Test that each undirected pair has both A->B and B->A rules"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        WITH pairs AS (
            SELECT DISTINCT product_a_id, product_b_id
            FROM main_intermediate.int_affinity__product_pairs
        ),
        rules AS (
            SELECT product_a_id, product_b_id
            FROM main_intermediate.int_affinity__association_rules
        )
        SELECT COUNT(*)
        FROM pairs p
        LEFT JOIN rules r1
            ON r1.product_a_id = p.product_a_id
           AND r1.product_b_id = p.product_b_id
        LEFT JOIN rules r2
            ON r2.product_a_id = p.product_b_id
           AND r2.product_b_id = p.product_a_id
        WHERE r1.product_a_id IS NULL OR r2.product_a_id IS NULL
    """)
    assert int(result) == 0, "Missing directional association rules for some product pairs"


def test_association_rules_formula_correctness(db):
    """Test that association rule formulas match raw order data for a sample of pairs"""
    conn, db_type = db
    result = execute_query(conn, db_type, """
        WITH order_products AS (
            SELECT DISTINCT order_id, product_id
            FROM main_staging.stg_basket__order_products
        ),
        total_orders AS (
            SELECT COUNT(DISTINCT order_id) AS total_orders
            FROM order_products
        ),
        orders_with_product AS (
            SELECT product_id, COUNT(DISTINCT order_id) AS orders_with_product
            FROM order_products
            GROUP BY product_id
        ),
        orders_with_both AS (
            SELECT
                a.product_id AS product_a_id,
                b.product_id AS product_b_id,
                COUNT(DISTINCT a.order_id) AS orders_with_both
            FROM order_products a
            JOIN order_products b
              ON a.order_id = b.order_id
             AND a.product_id != b.product_id
            GROUP BY a.product_id, b.product_id
        ),
        sample_pairs AS (
            SELECT product_a_id, product_b_id
            FROM main_intermediate.int_affinity__association_rules
            WHERE confidence < 0.999999
            ORDER BY product_a_id, product_b_id
            LIMIT 25
        ),
        expected AS (
            SELECT
                s.product_a_id,
                s.product_b_id,
                ob.orders_with_both,
                oa.orders_with_product AS orders_with_a,
                obb.orders_with_product AS orders_with_b,
                t.total_orders,
                CAST(ob.orders_with_both AS DOUBLE PRECISION) / CAST(t.total_orders AS DOUBLE PRECISION) AS support,
                CAST(ob.orders_with_both AS DOUBLE PRECISION) / CAST(oa.orders_with_product AS DOUBLE PRECISION) AS confidence,
                (CAST(ob.orders_with_both AS DOUBLE PRECISION) / CAST(oa.orders_with_product AS DOUBLE PRECISION)) /
                (CAST(obb.orders_with_product AS DOUBLE PRECISION) / CAST(t.total_orders AS DOUBLE PRECISION)) AS lift,
                (1.0 - (CAST(obb.orders_with_product AS DOUBLE PRECISION) / CAST(t.total_orders AS DOUBLE PRECISION))) /
                NULLIF(1.0 - (CAST(ob.orders_with_both AS DOUBLE PRECISION) / CAST(oa.orders_with_product AS DOUBLE PRECISION)), 0) AS conviction
            FROM sample_pairs s
            JOIN orders_with_both ob
              ON s.product_a_id = ob.product_a_id
             AND s.product_b_id = ob.product_b_id
            JOIN orders_with_product oa
              ON s.product_a_id = oa.product_id
            JOIN orders_with_product obb
              ON s.product_b_id = obb.product_id
            CROSS JOIN total_orders t
        ),
        compare AS (
            SELECT
                e.product_a_id,
                e.product_b_id,
                e.support AS expected_support,
                e.confidence AS expected_confidence,
                e.lift AS expected_lift,
                e.conviction AS expected_conviction,
                ar.support AS actual_support,
                ar.confidence AS actual_confidence,
                ar.lift AS actual_lift,
                ar.conviction AS actual_conviction
            FROM expected e
            JOIN main_intermediate.int_affinity__association_rules ar
              ON e.product_a_id = ar.product_a_id
             AND e.product_b_id = ar.product_b_id
        ),
        mismatches AS (
            SELECT *
            FROM compare
            WHERE
                ABS(actual_support - expected_support) > 1e-6
                OR ABS(actual_confidence - expected_confidence) > 1e-6
                OR ABS(actual_lift - expected_lift) > 1e-6
                OR (
                    (actual_conviction IS NULL AND expected_conviction IS NOT NULL)
                    OR (actual_conviction IS NOT NULL AND expected_conviction IS NULL)
                    OR (actual_conviction IS NOT NULL AND expected_conviction IS NOT NULL
                        AND ABS(actual_conviction - expected_conviction) > 1e-6)
                )
        )
        SELECT
            (SELECT COUNT(*) FROM compare) AS sample_count,
            (SELECT COUNT(*) FROM mismatches) AS mismatch_count
    """)

    assert int(result[0][0]) > 0, "No association rules available for formula validation"
    assert int(result[0][1]) == 0, f"Found {result[0][1]} association rule rows with incorrect formulas"


def test_fct_product_affinity_matrix_exists(db):
    """Test that fct_product_affinity_matrix model exists"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*) as cnt
        FROM information_schema.tables
        WHERE lower(table_schema) = 'main_marts'
        AND lower(table_name) = 'fct_product_affinity_matrix'
    """)
    assert int(result) == 1, "fct_product_affinity_matrix model does not exist"


def test_fct_product_affinity_matrix_columns(db):
    """Test that fact table has required columns"""
    conn, db_type = db
    required_columns = {
        'product_a_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_a_name': ['VARCHAR', 'TEXT'],
        'product_b_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_b_name': ['VARCHAR', 'TEXT'],
        'category_a_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'category_b_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'support': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'confidence': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'lift': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'conviction': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'orders_with_both': ['INTEGER', 'BIGINT', 'NUMBER']
    }

    columns = execute_query(conn, db_type, """
        SELECT lower(column_name), upper(data_type)
        FROM information_schema.columns
        WHERE lower(table_schema) = 'main_marts'
        AND lower(table_name) = 'fct_product_affinity_matrix'
    """)

    column_dict = {col[0]: col[1] for col in columns}

    for col_name, accepted_types in required_columns.items():
        assert col_name.lower() in column_dict, f"Missing column: {col_name}"
        actual_type = column_dict[col_name.lower()]
        assert actual_type in accepted_types, f"Wrong type for {col_name}: expected one of {accepted_types}, got {actual_type}"


def test_fct_affinity_filtering_rules_applied(db):
    """Test that filtering rules are applied correctly"""
    conn, db_type = db
    result = execute_query(conn, db_type, """
        SELECT
            COUNT(*) as total,
            MIN(support) as min_support,
            MIN(confidence) as min_confidence,
            MIN(lift) as min_lift
        FROM main_marts.fct_product_affinity_matrix
    """)

    assert int(result[0][0]) > 0, "fct_product_affinity_matrix is empty"
    # Agents adjust thresholds to achieve quality metrics - we validate quality, not specific thresholds
    assert float(result[0][1]) > 0, f"Support must be greater than 0, got {result[0][1]}"
    assert float(result[0][2]) > 0, f"Confidence must be greater than 0, got {result[0][2]}"
    assert float(result[0][3]) >= 1.0, f"Minimum lift {result[0][3]} must be at least 1.0 (filtered pairs should show positive correlation)"


def test_fct_affinity_no_same_category_pairs(db):
    """Test that same-category pairs are excluded"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main_marts.fct_product_affinity_matrix
        WHERE category_a_id = category_b_id
    """)
    assert int(result) == 0, "Found product pairs from the same category"


def test_fct_affinity_all_lift_above_one(db):
    """Test that all lift scores are > 1.0"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main_marts.fct_product_affinity_matrix
        WHERE lift <= 1.0
    """)
    assert int(result) == 0, "Found lift values <= 1.0 in final output"


def test_fct_affinity_minimum_high_lift_pairs(db):
    """Test that there are at least 100 pairs with lift > 1.5"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main_marts.fct_product_affinity_matrix
        WHERE lift > 1.5
    """)
    assert int(result) >= 100, f"Only found {result} pairs with lift > 1.5, expected at least 100"


def test_fct_affinity_is_filtered_subset_of_association_rules(db):
    """Test that fact table rows match association rules for the same pair"""
    conn, db_type = db
    # Use a Snowflake-compatible approach: compare with tolerance for floats
    # and explicit NULL handling instead of IS DISTINCT FROM
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*)
        FROM main_marts.fct_product_affinity_matrix f
        LEFT JOIN main_intermediate.int_affinity__association_rules ar
          ON f.product_a_id = ar.product_a_id
         AND f.product_b_id = ar.product_b_id
        WHERE ar.product_a_id IS NULL
           OR ABS(f.support - ar.support) > 1e-6
           OR ABS(f.confidence - ar.confidence) > 1e-6
           OR ABS(f.lift - ar.lift) > 1e-6
           OR (
               (f.conviction IS NULL AND ar.conviction IS NOT NULL)
               OR (f.conviction IS NOT NULL AND ar.conviction IS NULL)
               OR (f.conviction IS NOT NULL AND ar.conviction IS NOT NULL
                   AND ABS(f.conviction - ar.conviction) > 1e-6)
           )
           OR f.orders_with_both != ar.orders_with_both
    """)
    assert int(result) == 0, "Fact table rows are not consistent with association rules"


def test_rpt_recommended_bundles_exists(db):
    """Test that rpt_recommended_bundles model exists"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, """
        SELECT COUNT(*) as cnt
        FROM information_schema.tables
        WHERE lower(table_schema) = 'main_marts'
        AND lower(table_name) = 'rpt_recommended_bundles'
    """)
    assert int(result) == 1, "rpt_recommended_bundles model does not exist"


def test_rpt_recommended_bundles_columns(db):
    """Test that bundles report has required columns"""
    conn, db_type = db
    required_columns = {
        'bundle_rank': ['INTEGER', 'BIGINT', 'NUMBER'],
        'product_a_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_a_name': ['VARCHAR', 'TEXT'],
        'product_b_id': ['INTEGER', 'VARCHAR', 'BIGINT', 'NUMBER', 'TEXT'],
        'product_b_name': ['VARCHAR', 'TEXT'],
        'lift': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'confidence': ['DOUBLE', 'FLOAT', 'NUMBER'],
        'orders_with_both': ['INTEGER', 'BIGINT', 'NUMBER']
    }

    columns = execute_query(conn, db_type, """
        SELECT lower(column_name), upper(data_type)
        FROM information_schema.columns
        WHERE lower(table_schema) = 'main_marts'
        AND lower(table_name) = 'rpt_recommended_bundles'
    """)

    column_dict = {col[0]: col[1] for col in columns}

    for col_name, accepted_types in required_columns.items():
        assert col_name.lower() in column_dict, f"Missing column: {col_name}"
        actual_type = column_dict[col_name.lower()]
        assert actual_type in accepted_types, f"Wrong type for {col_name}: expected one of {accepted_types}, got {actual_type}"


def test_rpt_recommended_bundles_exactly_50_rows(db):
    """Test that bundles report contains exactly 50 rows"""
    conn, db_type = db
    result = execute_scalar(conn, db_type, "SELECT COUNT(*) FROM main_marts.rpt_recommended_bundles")
    assert int(result) == 50, f"Expected exactly 50 bundles, found {result}"


def test_rpt_recommended_bundles_ranked_correctly(db):
    """Test that bundles exactly match the top-50 by required ordering"""
    conn, db_type = db
    # Instead of EXCEPT (which can have floating-point precision issues on Snowflake),
    # use a join-based comparison approach
    result = execute_query(conn, db_type, """
        WITH ranked AS (
            SELECT
                ROW_NUMBER() OVER (
                    ORDER BY
                        lift DESC,
                        confidence DESC,
                        orders_with_both DESC,
                        product_a_id ASC,
                        product_b_id ASC
                ) AS expected_rank,
                product_a_id,
                product_b_id,
                lift,
                confidence,
                orders_with_both
            FROM main_marts.fct_product_affinity_matrix
        ),
        expected AS (
            SELECT *
            FROM ranked
            WHERE expected_rank <= 50
        )
        SELECT COUNT(*)
        FROM expected e
        LEFT JOIN main_marts.rpt_recommended_bundles r
            ON e.product_a_id = r.product_a_id
           AND e.product_b_id = r.product_b_id
           AND e.expected_rank = r.bundle_rank
        WHERE r.product_a_id IS NULL
           OR ABS(e.lift - r.lift) > 1e-6
           OR ABS(e.confidence - r.confidence) > 1e-6
           OR e.orders_with_both != r.orders_with_both
    """)

    mismatch_count = int(result[0][0])
    assert mismatch_count == 0, f"Bundles report does not match the required top-50 ordering ({mismatch_count} mismatches)"
