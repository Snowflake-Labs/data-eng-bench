/*
================================================================================
generate_schema_name - Custom Schema Naming Logic
================================================================================
Override dbt's default schema naming to support our multi-environment setup.

Our environments:
- dev: Each developer gets their own schema (dev_marcus, dev_sarah, etc.)
- staging: Shared staging schema for testing
- prod: Production schemas by domain (analytics, marts, staging)

This has been modified many times and the logic is... evolved.

HISTORY:
- 2022-01-01: Simple prefix approach
- 2022-06-01: Added developer-specific schemas for dev
- 2023-01-01: Added domain-based schemas for prod
- 2023-06-01: Added CI schema support
- 2024-01-01: Added temporary schema cleanup
- 2024-04-01: Fixed the bug where prod schemas got prefixed (oops)

Code Review:
- Marcus: "I don't understand this logic"
- Sarah: "Nobody does. It just works. Don't touch it."
================================================================================
*/

{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}
    {%- set target_name = target.name -%}

    {#
    PRODUCTION: Use domain-based schemas
    - staging models -> ANALYTICS_STAGING
    - intermediate models -> ANALYTICS_INTERMEDIATE
    - marts models -> ANALYTICS (the main schema)
    #}
    {%- if target_name == 'prod' -%}

        {%- if custom_schema_name is not none -%}
            {# Explicit schema override in model config #}
            {{ custom_schema_name | trim }}

        {%- elif node.fqn[1] == 'staging' -%}
            ANALYTICS_STAGING

        {%- elif node.fqn[1] == 'intermediate' -%}
            ANALYTICS_INTERMEDIATE

        {%- elif node.fqn[1] == 'marts' -%}
            {# Further split marts by domain #}
            {%- if node.fqn | length > 2 -%}
                {%- set domain = node.fqn[2] -%}
                {%- if domain in ['sales', 'finance', 'marketing'] -%}
                    ANALYTICS_{{ domain | upper }}
                {%- else -%}
                    ANALYTICS
                {%- endif -%}
            {%- else -%}
                ANALYTICS
            {%- endif -%}

        {%- else -%}
            ANALYTICS

        {%- endif -%}

    {#
    STAGING (environment): Shared schema with prefix
    #}
    {%- elif target_name == 'staging' -%}

        {%- if custom_schema_name is not none -%}
            {{ default_schema }}_{{ custom_schema_name | trim }}
        {%- else -%}
            {{ default_schema }}
        {%- endif -%}

    {#
    CI: Use unique schema per PR to avoid conflicts
    Expects CI_SCHEMA_SUFFIX env var to be set (usually PR number)
    #}
    {%- elif target_name == 'ci' -%}

        {%- set ci_suffix = env_var('CI_SCHEMA_SUFFIX', 'ci') -%}
        CI_{{ ci_suffix }}_{{ custom_schema_name | default(default_schema, true) | trim }}

    {#
    DEV: Developer-specific schemas
    Expects developer name in target schema (e.g., dev_marcus)
    #}
    {%- elif target_name == 'dev' -%}

        {%- if custom_schema_name is not none -%}
            {{ default_schema }}_{{ custom_schema_name | trim }}
        {%- else -%}
            {{ default_schema }}
        {%- endif -%}

    {#
    UNKNOWN TARGET: Fall back to dbt default behavior
    (with warning comment)
    #}
    {%- else -%}

        {# -- WARNING: Unknown target '{{ target_name }}', using default schema logic #}
        {%- if custom_schema_name is not none -%}
            {{ default_schema }}_{{ custom_schema_name | trim }}
        {%- else -%}
            {{ default_schema }}
        {%- endif -%}

    {%- endif -%}

{%- endmacro %}


{#
================================================================================
RELATED MACROS
================================================================================
#}

{# Get the full qualified table name for a model #}
{% macro get_full_table_name(model_name) %}
    {{ target.database }}.{{ generate_schema_name(none, graph.nodes['model.' ~ project_name ~ '.' ~ model_name]) }}.{{ model_name }}
{% endmacro %}


{# Check if current run is production #}
{% macro is_production() %}
    {{ target.name == 'prod' }}
{% endmacro %}


{# Get schema prefix for current environment #}
{% macro get_schema_prefix() %}
    {%- if target.name == 'prod' -%}
        ANALYTICS
    {%- elif target.name == 'staging' -%}
        STG
    {%- elif target.name == 'ci' -%}
        CI_{{ env_var('CI_SCHEMA_SUFFIX', 'test') }}
    {%- else -%}
        DEV_{{ target.schema | upper }}
    {%- endif -%}
{% endmacro %}
