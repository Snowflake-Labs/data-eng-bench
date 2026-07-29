#!/usr/bin/env python3
"""
Data quality fix: populate RAW_SAP.VBAP.product_id from ORDERS.ORDER_LINES.

RAW_SAP.VBAP.product_id is NULL for all rows in the source database.  The correct
product_id values exist in ORDERS.ORDER_LINES and can be joined on order_line_id.
Without this fix int_sales__order_lines.product_id is always NULL, causing the
dbt-product-return-analysis verifier component_3 row-count check to evaluate 0
products and pass bug-for-bug regardless of what the agent builds.

Run once after the database is available, before `dbt run`.
"""
import duckdb
import os

DB_PATH = os.environ.get("DUCKDB_PATH", "/app/database/retail.duckdb")

conn = duckdb.connect(DB_PATH)
conn.execute("""
    UPDATE RAW_SAP.VBAP
    SET product_id = ol.product_id
    FROM ORDERS.ORDER_LINES ol
    WHERE VBAP.order_line_id = ol.order_line_id
      AND ol.product_id IS NOT NULL
""")
n = conn.execute(
    "SELECT COUNT(*) FROM RAW_SAP.VBAP WHERE product_id IS NOT NULL"
).fetchone()[0]
print(f"fix_data: RAW_SAP.VBAP.product_id populated — {n} rows now non-null")
conn.close()
