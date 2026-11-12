"""Regression checks for the inventory task's cancellation rule."""

import re
import runpy
from pathlib import Path
from unittest.mock import patch

import duckdb
import pytest

TASK = Path(__file__).resolve().parents[1] / "tasks" / "dbt-fix-inventory-balance"


@pytest.fixture
def connection():
    conn = duckdb.connect(":memory:")
    conn.execute("""
        CREATE TABLE stg_orders__orders AS
        SELECT * FROM (VALUES
            ('o1', DATE '2024-01-01', 'COMPLETED'),
            ('o2', DATE '2024-01-02', 'CANCELLED'),
            ('o3', DATE '2024-01-03', 'REFUNDED')
        ) AS orders(order_id, ordered_at, status);
        CREATE TABLE stg_orders__order_lines AS
        SELECT * FROM (VALUES
            ('l1', 'o1', 'v1', 1, 10),
            ('l2', 'o2', 'v1', 2, 20),
            ('l3', 'o3', 'v1', 3, 30)
        ) AS lines(order_line_id, order_id, variant_id, quantity_ordered, line_total);
        CREATE TABLE stg_product__product_variants AS
        SELECT 'v1' AS variant_id, 'p1' AS product_id;
        CREATE TABLE stg_product__products AS
        SELECT 'p1' AS product_id, 'Product' AS product_name;
    """)
    yield conn
    conn.close()


@pytest.fixture
def verifier():
    with patch("os.path.exists", return_value=False):
        return runpy.run_path(str(TASK / "tests" / "test_outputs.py"))


def test_reference_excludes_cancelled_and_refunded(connection):
    script = (TASK / "solution" / "solve.sh").read_text()
    sql = script.split(
        "cat > models/marts/inventory/fct_inventory_balance.sql << 'EOF'\n", 1
    )[1]
    sql = sql.split("\nEOF", 1)[0]
    sql = re.sub(r"\{\{\s*config\(.*?\)\s*\}\}", "", sql, flags=re.DOTALL)
    sql = re.sub(r"\{\{\s*ref\('([^']+)'\)\s*\}\}", r"main.\1", sql)
    rows = connection.execute(sql).fetchall()
    assert [row[3] for row in rows] == ["l1"]


def test_verifier_accepts_candidate_that_excludes_cancelled(connection, verifier):
    connection.execute("""
        CREATE TABLE fct_inventory_balance AS
        SELECT 'p1' AS product_id, 'l1' AS order_line_id, 10 AS cumulative_revenue
    """)
    verifier["test_all_order_lines_present"]((connection, "duckdb"))
    verifier["test_final_cumulative_matches_total"]((connection, "duckdb"))
    verifier["test_cancelled_orders_excluded"]((connection, "duckdb"))


@pytest.mark.parametrize("status", ["CANCELLED", "REFUNDED"])
def test_verifier_rejects_candidate_containing_excluded_order(
    connection, verifier, status
):
    connection.execute(
        """
        CREATE TABLE fct_inventory_balance AS
        SELECT lines.order_line_id
        FROM stg_orders__order_lines lines
        JOIN stg_orders__orders orders USING (order_id)
        WHERE orders.status = ?
    """,
        [status],
    )
    with pytest.raises(
        AssertionError, match="order lines from cancelled/refunded orders"
    ):
        verifier["test_cancelled_orders_excluded"]((connection, "duckdb"))
