#!/usr/bin/env python3
"""Migrate retail.duckdb to Snowflake as DBT_BENCH_RETAIL.

Reads the DuckDB file extracted from the base Docker image, enumerates all
schemas/tables, and uploads each to Snowflake using write_pandas.

Usage:
    python migrate_duckdb.py retail.duckdb
    python migrate_duckdb.py retail.duckdb --force  # recreate if exists
"""

import argparse
import re
import sys
from pathlib import Path

import duckdb
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas


SF_DATABASE = "DBT_BENCH_RETAIL"

# DuckDB type -> Snowflake type mapping for empty table DDL.
# Non-empty tables use write_pandas with auto_create_table which infers from pandas dtypes.
_DUCKDB_TO_SF_TYPE = {
    "VARCHAR": "VARCHAR",
    "BOOLEAN": "BOOLEAN",
    "INTEGER": "INTEGER",
    "BIGINT": "BIGINT",
    "HUGEINT": "NUMBER(38,0)",
    "UBIGINT": "NUMBER(20,0)",
    "DOUBLE": "FLOAT",
    "FLOAT": "FLOAT",
    "DATE": "DATE",
    "TIME": "TIME",
    "TIMESTAMP": "TIMESTAMP_NTZ",
    "TIMESTAMP WITH TIME ZONE": "TIMESTAMP_TZ",
    "JSON": "VARIANT",
    "INTERVAL": "VARCHAR",
}
_DECIMAL_RE = re.compile(r"^DECIMAL\(\d+,\s*\d+\)$")


def duckdb_type_to_snowflake(duckdb_type: str) -> str:
    """Map a DuckDB column type to a Snowflake column type."""
    if duckdb_type in _DUCKDB_TO_SF_TYPE:
        return _DUCKDB_TO_SF_TYPE[duckdb_type]
    # DECIMAL(p,s) -> NUMBER(p,s)
    if _DECIMAL_RE.match(duckdb_type):
        return duckdb_type.replace("DECIMAL", "NUMBER")
    return "VARCHAR"


def get_snowflake_connection() -> snowflake.connector.SnowflakeConnection:
    """Connect to Snowflake via a named connection (SNOWFLAKE_CONNECTION_NAME, default "dbt_bench") or explicit env vars."""
    import os

    conn_name = os.environ.get("SNOWFLAKE_CONNECTION_NAME", "dbt_bench")
    try:
        return snowflake.connector.connect(connection_name=conn_name)
    except Exception as e:
        print(f"Named connection '{conn_name}' failed ({e}), trying env vars...")
        return snowflake.connector.connect(
            account=os.environ["SNOWFLAKE_ACCOUNT"],
            host=os.environ.get("SNOWFLAKE_HOST") or None,
            user=os.environ["SNOWFLAKE_USER"],
            password=os.environ["SNOWFLAKE_PASSWORD"],
            warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE"),
            role=os.environ.get("SNOWFLAKE_ROLE"),
        )


def database_exists(sf_conn: snowflake.connector.SnowflakeConnection) -> bool:
    cursor = sf_conn.cursor()
    try:
        cursor.execute(f"SHOW DATABASES LIKE '{SF_DATABASE}'")
        return len(cursor.fetchall()) > 0
    finally:
        cursor.close()


def get_existing_tables(sf_conn: snowflake.connector.SnowflakeConnection) -> set[str]:
    """Return set of 'SCHEMA.TABLE' already in the database."""
    existing: set[str] = set()
    cur = sf_conn.cursor()
    try:
        cur.execute(f"SHOW SCHEMAS IN DATABASE {SF_DATABASE}")
        schemas = [r[1] for r in cur.fetchall() if r[1] not in ("INFORMATION_SCHEMA", "PUBLIC")]
        for schema in schemas:
            cur.execute(f'SHOW TABLES IN SCHEMA {SF_DATABASE}."{schema}"')
            for r in cur.fetchall():
                existing.add(f"{schema}.{r[1]}")
    finally:
        cur.close()
    return existing


def migrate(duckdb_path: str, force: bool = False, resume: bool = False) -> None:
    sf_conn = get_snowflake_connection()
    cur = sf_conn.cursor()

    try:
        if database_exists(sf_conn):
            if resume:
                print(f"Resuming migration into existing {SF_DATABASE}...")
            elif not force:
                print(f"Database {SF_DATABASE} already exists. Use --force to recreate or --resume to continue.")
                return
            else:
                print(f"Dropping existing database {SF_DATABASE}...")
                cur.execute(f"DROP DATABASE IF EXISTS {SF_DATABASE}")

        if not resume:
            print(f"Creating database {SF_DATABASE}...")
            cur.execute(f"CREATE DATABASE IF NOT EXISTS {SF_DATABASE}")

        # Build set of already-uploaded tables for resume mode
        existing_tables: set[str] = set()
        if resume:
            existing_tables = get_existing_tables(sf_conn)
            print(f"  Found {len(existing_tables)} existing tables to skip")

        # Connect to DuckDB and enumerate all schemas/tables
        duck = duckdb.connect(duckdb_path, read_only=True)
        tables = duck.execute("SHOW ALL TABLES").fetchall()

        # SHOW ALL TABLES returns: database, schema, name, column_names, column_types, temporary
        schemas_seen: set[str] = set()
        failed_tables: list[str] = []
        total = len(tables)
        print(f"Found {total} tables to migrate")

        skipped = 0
        for i, row in enumerate(tables, 1):
            schema_name = row[1].upper()
            table_name = row[2].upper()

            # Skip tables already uploaded in a previous run
            if f"{schema_name}.{table_name}" in existing_tables:
                skipped += 1
                continue

            # Create schema if not seen yet
            if schema_name not in schemas_seen:
                print(f"  Creating schema {SF_DATABASE}.\"{schema_name}\"")
                cur.execute(
                    f'CREATE SCHEMA IF NOT EXISTS {SF_DATABASE}."{schema_name}"'
                )
                schemas_seen.add(schema_name)

            try:
                # Read table into pandas
                duck_schema = row[1]
                duck_table = row[2]
                try:
                    df = duck.execute(
                        f'SELECT * FROM "{duck_schema}"."{duck_table}"'
                    ).fetchdf()
                except Exception as e:
                    # Some tables have extreme date values (e.g., 5877642 BC) that
                    # can't be converted to pandas datetime. Fall back to casting
                    # problematic columns as VARCHAR.
                    print(f"    fetchdf failed ({e}), retrying with string cast...")
                    col_names = row[3]
                    col_types = row[4]
                    cast_cols = []
                    for c, t in zip(col_names, col_types):
                        if t in ("DATE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE"):
                            cast_cols.append(f'CAST("{c}" AS VARCHAR) AS "{c}"')
                        else:
                            cast_cols.append(f'"{c}"')
                    select_expr = ", ".join(cast_cols)
                    df = duck.execute(
                        f'SELECT {select_expr} FROM "{duck_schema}"."{duck_table}"'
                    ).fetchdf()

                print(f"  [{i}/{total}] {schema_name}.{table_name} ({len(df)} rows)")

                if len(df) == 0:
                    # For empty tables, use DuckDB column type info from SHOW ALL TABLES
                    col_names = row[3]  # column_names
                    col_types = row[4]  # column_types
                    cols = ", ".join(
                        f'"{c}" {duckdb_type_to_snowflake(t)}'
                        for c, t in zip(col_names, col_types)
                    )
                    cur.execute(
                        f'CREATE TABLE IF NOT EXISTS {SF_DATABASE}."{schema_name}"."{table_name}" ({cols})'
                    )
                    continue

                # Upload to Snowflake
                write_pandas(
                    sf_conn,
                    df,
                    table_name=table_name,
                    database=SF_DATABASE,
                    schema=schema_name,
                    auto_create_table=True,
                    overwrite=True,
                    use_logical_type=True,
                )
            except Exception as e:
                failed_tables.append(f"{schema_name}.{table_name}")
                print(f"  [{i}/{total}] SKIP {schema_name}.{table_name}: {e}")

        duck.close()

        # Grant privileges to PUBLIC
        print("Granting privileges to PUBLIC...")
        cur.execute(f"GRANT USAGE ON DATABASE {SF_DATABASE} TO ROLE PUBLIC")
        for schema in schemas_seen:
            cur.execute(
                f'GRANT USAGE ON SCHEMA {SF_DATABASE}."{schema}" TO ROLE PUBLIC'
            )
            cur.execute(
                f'GRANT SELECT ON ALL TABLES IN SCHEMA {SF_DATABASE}."{schema}" TO ROLE PUBLIC'
            )
            cur.execute(
                f'GRANT SELECT ON FUTURE TABLES IN SCHEMA {SF_DATABASE}."{schema}" TO ROLE PUBLIC'
            )

        uploaded = total - skipped - len(failed_tables)
        print(f"Migration complete: {uploaded} tables uploaded, {skipped} skipped, {len(failed_tables)} failed, {len(schemas_seen)} schemas")
        if failed_tables:
            print(f"Failed tables: {', '.join(failed_tables[:20])}")
            if len(failed_tables) > 20:
                print(f"  ... and {len(failed_tables) - 20} more")

    finally:
        cur.close()
        sf_conn.close()


def main():
    parser = argparse.ArgumentParser(description="Migrate DuckDB to Snowflake")
    parser.add_argument("duckdb_path", help="Path to retail.duckdb file")
    parser.add_argument(
        "--force", action="store_true", help="Recreate database if it exists"
    )
    parser.add_argument(
        "--resume", action="store_true", help="Resume incomplete migration (skip existing tables)"
    )
    args = parser.parse_args()

    if not Path(args.duckdb_path).exists():
        print(f"ERROR: DuckDB file not found: {args.duckdb_path}")
        sys.exit(1)

    migrate(args.duckdb_path, force=args.force, resume=args.resume)


if __name__ == "__main__":
    main()
