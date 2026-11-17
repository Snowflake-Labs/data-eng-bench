"""Exercise the real sales verifier against small DuckDB relations.

Run: python -m pytest tests/test_inventory_turnover_verifier.py -q
Requires pytest and duckdb; no dbt project or external warehouse is needed.
"""
import importlib.util
from pathlib import Path

import duckdb
import pytest

TASK = Path(__file__).resolve().parents[1] / 'tasks/dbt-inventory-turnover-analysis'


@pytest.fixture
def verifier(monkeypatch):
    monkeypatch.setenv('DB_TYPE', 'duckdb')
    spec = importlib.util.spec_from_file_location('inventory_verifier', TASK / 'tests/test_outputs.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def db():
    con = duckdb.connect()
    con.execute('CREATE SCHEMA analytics')
    con.execute('CREATE TABLE main.stg_orders__orders(order_id VARCHAR, warehouse_id VARCHAR, fulfillment_status VARCHAR, shipped_at TIMESTAMP, delivered_at TIMESTAMP)')
    con.execute('CREATE TABLE main.stg_orders__order_lines(order_id VARCHAR, variant_id VARCHAR, quantity_ordered DECIMAL(18,2))')
    con.execute('CREATE TABLE main.stg_product__product_variants(variant_id VARCHAR, sku VARCHAR)')
    con.execute('CREATE TABLE main.stg_inventory__inventory_levels(variant_id VARCHAR, warehouse_id VARCHAR)')
    con.execute('CREATE TABLE analytics.rpt_inventory_turnover_analysis(sku VARCHAR, warehouse_id VARCHAR, total_units_sold DECIMAL(18,2), current_quantity_on_hand INTEGER)')
    con.execute("INSERT INTO main.stg_product__product_variants VALUES ('v', 'sku')")
    con.execute("INSERT INTO main.stg_orders__orders VALUES ('o', 'A', 'FULFILLED', '2025-01-03', NULL)")
    con.execute("INSERT INTO main.stg_orders__order_lines VALUES ('o', 'v', 3)")
    yield con
    con.close()


@pytest.mark.parametrize('snapshots', [0, 1, 2, 5])
def test_snapshot_count_does_not_change_sales(db, verifier, snapshots):
    for _ in range(snapshots):
        db.execute("INSERT INTO main.stg_inventory__inventory_levels VALUES ('v', 'A')")
    db.execute("INSERT INTO analytics.rpt_inventory_turnover_analysis VALUES ('sku', 'A', 3, 100)")
    verifier.test_sales_reconciliation_sample((db, 'duckdb'))


def test_sales_are_not_assigned_to_another_inventory_warehouse(db, verifier):
    db.execute("INSERT INTO main.stg_inventory__inventory_levels VALUES ('v', 'A'), ('v', 'B')")
    db.execute("INSERT INTO analytics.rpt_inventory_turnover_analysis VALUES ('sku', 'A', 3, 100), ('sku', 'B', 0, 99)")
    verifier.test_sales_reconciliation_sample((db, 'duckdb'))


def test_doubled_sales_are_rejected(db, verifier):
    db.execute("INSERT INTO main.stg_inventory__inventory_levels VALUES ('v', 'A'), ('v', 'A')")
    db.execute("INSERT INTO analytics.rpt_inventory_turnover_analysis VALUES ('sku', 'A', 6, 100)")
    with pytest.raises(AssertionError, match='model=6'):
        verifier.test_sales_reconciliation_sample((db, 'duckdb'))


def test_zero_sales_are_rejected_when_order_exists(db, verifier):
    db.execute("INSERT INTO main.stg_inventory__inventory_levels VALUES ('v', 'A')")
    db.execute("INSERT INTO analytics.rpt_inventory_turnover_analysis VALUES ('sku', 'A', 0, 100)")
    with pytest.raises(AssertionError, match='model=0'):
        verifier.test_sales_reconciliation_sample((db, 'duckdb'))


def test_zero_stock_does_not_skip_sales_reconciliation(db, verifier):
    db.execute("INSERT INTO main.stg_inventory__inventory_levels VALUES ('v', 'A')")
    db.execute("INSERT INTO analytics.rpt_inventory_turnover_analysis VALUES ('sku', 'A', 6, 0)")
    with pytest.raises(AssertionError, match='model=6'):
        verifier.test_sales_reconciliation_sample((db, 'duckdb'))


def test_window_status_and_delivered_fallback(db, verifier):
    db.execute("""INSERT INTO main.stg_orders__orders VALUES
        ('boundary', 'A', 'FULFILLED', '2024-07-07', NULL),
        ('old', 'A', 'FULFILLED', '2024-07-06', NULL),
        ('pending', 'A', 'PENDING', '2025-01-02', NULL),
        ('missing', 'A', 'FULFILLED', NULL, NULL),
        ('delivered', 'A', 'FULFILLED', NULL, '2025-01-02')""")
    db.execute("""INSERT INTO main.stg_orders__order_lines VALUES
        ('boundary','v',2),('old','v',100),('pending','v',100),
        ('missing','v',100),('delivered','v',4)""")
    db.execute("INSERT INTO main.stg_inventory__inventory_levels VALUES ('v', 'A')")
    db.execute("INSERT INTO analytics.rpt_inventory_turnover_analysis VALUES ('sku', 'A', 9, 100)")
    verifier.test_sales_reconciliation_sample((db, 'duckdb'))
