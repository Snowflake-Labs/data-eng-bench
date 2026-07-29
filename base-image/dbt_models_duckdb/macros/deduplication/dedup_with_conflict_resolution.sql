/*
================================================================================
dedup_with_conflict_resolution - Production Deduplication Macro
================================================================================
This macro handles complex deduplication scenarios we've encountered in production.

Standard ROW_NUMBER() dedup doesn't handle:
1. Records with same timestamp but different values
2. Conflict resolution when "newer" isn't always "better"
3. Null handling in order-by columns
4. Source-system priority when merging data

USAGE:
{{ dedup_with_conflict_resolution(
    relation='source_table',
    partition_by=['order_id', 'line_item_id'],
    order_by=['updated_at DESC', 'created_at DESC'],
    conflict_resolution={
        'status': 'prefer_non_null',
        'amount': 'prefer_non_zero',
        'source_system': ['SAP', 'POS', 'LEGACY']  -- priority order
    }
) }}

HISTORY:
- v1.0 (2023-06-01): Initial implementation
- v1.1 (2023-08-15): Added null handling for order-by columns
- v1.2 (2024-01-10): Added conflict_resolution parameter after HomeStyle incident
- v1.3 (2024-03-22): Added source_system priority after multi-source merge issues
- v1.4 (2024-07-01): Performance optimization for large tables (>100M rows)

Code Review:
- Marcus: "Why is this so complex?"
- Sarah: "Because production is complex."
- Marcus: "Fair point."
================================================================================
*/

{% macro dedup_with_conflict_resolution(
    relation,
    partition_by,
    order_by=none,
    conflict_resolution=none,
    include_dedup_rank=false
) %}

{#
    Validate inputs
#}
{% if partition_by is none or partition_by | length == 0 %}
    {{ exceptions.raise_compiler_error("partition_by is required and cannot be empty") }}
{% endif %}

{#
    Build partition clause
#}
{% set partition_clause = partition_by | join(', ') %}

{#
    Build order clause with null handling
    NULLs should be treated as "worse" than any value for dedup purposes
#}
{% set order_clause_parts = [] %}

{% if order_by is not none %}
    {% for col in order_by %}
        {% set col_clean = col | trim %}

        {# Handle DESC/ASC suffix #}
        {% if ' DESC' in col_clean | upper %}
            {% set col_name = col_clean | replace(' DESC', '') | replace(' desc', '') | trim %}
            {% set _ = order_clause_parts.append(col_name ~ ' DESC NULLS LAST') %}
        {% elif ' ASC' in col_clean | upper %}
            {% set col_name = col_clean | replace(' ASC', '') | replace(' asc', '') | trim %}
            {% set _ = order_clause_parts.append(col_name ~ ' ASC NULLS LAST') %}
        {% else %}
            {% set _ = order_clause_parts.append(col_clean ~ ' DESC NULLS LAST') %}
        {% endif %}
    {% endfor %}
{% endif %}

{#
    Add conflict resolution logic to order clause
#}
{% if conflict_resolution is not none %}
    {% for col, strategy in conflict_resolution.items() %}
        {% if strategy == 'prefer_non_null' %}
            {% set _ = order_clause_parts.append('CASE WHEN ' ~ col ~ ' IS NOT NULL THEN 0 ELSE 1 END') %}
        {% elif strategy == 'prefer_non_zero' %}
            {% set _ = order_clause_parts.append('CASE WHEN ' ~ col ~ ' != 0 AND ' ~ col ~ ' IS NOT NULL THEN 0 ELSE 1 END') %}
        {% elif strategy == 'prefer_non_empty' %}
            {% set _ = order_clause_parts.append('CASE WHEN ' ~ col ~ ' IS NOT NULL AND ' ~ col ~ ' != \'\' THEN 0 ELSE 1 END') %}
        {% elif strategy is iterable and strategy is not string %}
            {# It's a list - treat as priority order #}
            {% set case_parts = [] %}
            {% for idx, val in enumerate(strategy) %}
                {% set _ = case_parts.append('WHEN ' ~ col ~ ' = \'' ~ val ~ '\' THEN ' ~ idx) %}
            {% endfor %}
            {% set _ = order_clause_parts.append('CASE ' ~ case_parts | join(' ') ~ ' ELSE 999 END') %}
        {% endif %}
    {% endfor %}
{% endif %}

{# Default order if nothing specified #}
{% if order_clause_parts | length == 0 %}
    {% set _ = order_clause_parts.append('1') %}
{% endif %}

{% set order_clause = order_clause_parts | join(', ') %}

{#
    Generate the deduplication SQL
#}
SELECT
    {% if include_dedup_rank %}
    _dedup_rank,
    {% endif %}
    * EXCLUDE (_dedup_rank)
FROM (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY {{ partition_clause }}
            ORDER BY {{ order_clause }}
        ) AS _dedup_rank
    FROM {{ relation }}
)
WHERE _dedup_rank = 1

{% endmacro %}


/*
================================================================================
CONVENIENCE WRAPPERS
================================================================================
*/

{# Simple dedup by timestamp #}
{% macro dedup_by_timestamp(relation, partition_by, timestamp_col='updated_at') %}
    {{ dedup_with_conflict_resolution(
        relation=relation,
        partition_by=partition_by,
        order_by=[timestamp_col ~ ' DESC']
    ) }}
{% endmacro %}


{# Dedup with source system priority (common pattern) #}
{% macro dedup_with_source_priority(relation, partition_by, source_col='source_system', priority_list=none) %}
    {% set default_priority = ['SAP', 'SAP_HOMESTYLE', 'POS', 'B2B_PORTAL', 'LEGACY'] %}
    {% set actual_priority = priority_list if priority_list is not none else default_priority %}

    {{ dedup_with_conflict_resolution(
        relation=relation,
        partition_by=partition_by,
        order_by=['updated_at DESC'],
        conflict_resolution={source_col: actual_priority}
    ) }}
{% endmacro %}
