#!/bin/bash
# Builds only the upstream reference models (int_sales__orders_enriched, int_sales__order_lines).
# Used by the verifier so it does NOT overwrite the agent's /app/dbt_project.
# solve.sh also calls this before creating the reference dbt_project.
set -euo pipefail

echo "Building reference source models..."
mkdir -p ~/.dbt
cd /app/dbt_transforms

if [ -f profiles.yml ]; then
  cp profiles.yml ~/.dbt/profiles.yml
else
  cat > ~/.dbt/profiles.yml << 'EOF'
retail_dw_master:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
EOF
fi

dbt deps || true
dbt run --select int_sales__orders_enriched int_sales__order_lines
