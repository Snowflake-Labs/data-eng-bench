#!/usr/bin/env python3
"""
Bimodal Gaussian Criteria Sampler for dbt Model Realism

Distribution: Bimodal Gaussian with peaks at 50 and 150 criteria
- Peak 1: ~50 criteria (sparse documentation, rushed developer)
- Peak 2: ~150 criteria (heavy documentation, senior engineer)
- Valley in middle (fewer models with 80-120 criteria)
"""

import numpy as np
import random
from typing import List, Dict

# =============================================================================
# ALL 208 CRITERIA FROM DBT_MODEL_QUALITY_METRICS.md
# =============================================================================

CRITERIA = {
    # Category 1: Code Quality & Style (22 criteria)
    "cte_instead_of_subqueries": "Uses CTEs instead of nested subqueries",
    "cte_single_responsibility": "Each CTE has single responsibility",
    "cte_logically_ordered": "CTEs are logically ordered (source → transform → output)",
    "cte_names_descriptive": "CTE names are descriptive (not cte1, cte2)",
    "final_cte_named": "Final CTE named 'final' or similar",
    "snake_case_columns": "snake_case for columns",
    "snake_case_ctes": "snake_case for CTEs",
    "meaningful_column_names": "Meaningful column names (not col1, value)",
    "boolean_prefix_is_has": "Boolean columns prefixed is_/has_",
    "date_suffix_at_date": "Date columns suffixed _at/_date",
    "id_suffix": "ID columns suffixed _id",
    "consistent_indentation": "Consistent indentation throughout",
    "sql_keywords_consistent_case": "SQL keywords lowercase/uppercase consistent",
    "one_column_per_line": "One column per line in SELECT",
    "trailing_commas": "Trailing commas used",
    "proper_line_length": "Proper line length (<120 chars)",
    "blank_lines_between_ctes": "Blank lines between CTEs",
    "explicit_column_selection": "Explicit column selection (no SELECT *)",
    "meaningful_table_aliases": "Table aliases are meaningful",
    "join_conditions_formatted": "JOIN conditions properly formatted",
    "where_conditions_formatted": "WHERE conditions properly formatted",
    "case_statements_indented": "CASE statements properly indented",

    # Category 2: Documentation (19 criteria)
    "header_purpose_block": "Purpose/description block at top",
    "author_attribution": "Author attribution (@author: tag)",
    "created_modified_dates": "Created/modified dates",
    "dependencies_listed": "Dependencies listed in header",
    "output_description": "Output description (what model produces)",
    "complex_logic_explained": "Complex logic explained with comments",
    "business_rules_documented": "Business rules documented (why not what)",
    "magic_numbers_explained": "Magic numbers explained with comments",
    "todo_fixme_annotations": "TODO/FIXME annotations present",
    "ticket_references": "Ticket references (JIRA-123, DATA-456)",
    "model_level_description_yaml": "Model-level description in schema.yml",
    "all_columns_documented_yaml": "All columns documented in schema.yml",
    "doc_blocks_used": "Doc blocks used ({{ doc() }})",
    "column_descriptions_meaningful": "Column descriptions meaningful",
    "examples_provided": "Examples provided where helpful",
    "schedule_frequency_noted": "Schedule/frequency noted",
    "performance_characteristics": "Performance characteristics documented",
    "alert_thresholds_documented": "Alert thresholds documented",
    "data_owner_specified": "Data owner specified",

    # Category 3: Testing Strategy (18 criteria)
    "pk_unique_test": "Primary key has unique test",
    "pk_not_null_test": "Primary key has not_null test",
    "fk_relationships_test": "Foreign keys have relationships test",
    "enum_accepted_values": "Enum columns have accepted_values",
    "numeric_range_tests": "Numeric columns have range tests",
    "unique_combination_test": "unique_combination_of_columns used",
    "multi_tenant_keys": "Multi-tenant keys include tenant ID",
    "history_keys_timestamp": "History keys include timestamp",
    "row_count_validation": "Row count validation tests",
    "freshness_tests": "Freshness tests defined",
    "regex_pattern_tests": "Regex pattern tests (email, phone)",
    "date_range_tests": "Date range tests",
    "singular_test_files": "Singular test files exist",
    "custom_generic_tests": "Custom generic tests defined",
    "test_coverage_80pct": "Test coverage > 80% columns",
    "unit_tests_dbt18": "Unit tests (dbt 1.8+)",
    "data_contracts_enforced": "Data contracts enforced",
    "test_severity_levels": "Test severity levels set",

    # Category 4: Maintainability (15 criteria)
    "single_responsibility": "Single responsibility per model",
    "reusable_intermediate": "Reusable intermediate models",
    "no_duplicated_logic": "Logic not duplicated across models",
    "macros_for_repeated": "Macros used for repeated logic",
    "no_magic_numbers": "No magic numbers (use vars)",
    "thresholds_configurable": "Thresholds are configurable",
    "date_ranges_parameterized": "Date ranges parameterized",
    "feature_flags": "Feature flags for optional logic",
    "schema_drift_handled": "Schema drift handled",
    "explicit_column_lists": "Explicit column lists",
    "graceful_null_handling": "Graceful NULL handling",
    "default_values_provided": "Default values provided",
    "related_logic_grouped": "Related logic grouped in CTEs",
    "clear_separation_concerns": "Clear separation of concerns",
    "consistent_patterns": "Consistent patterns across models",

    # Category 5: dbt Best Practices (19 criteria)
    "staging_naming_convention": "Staging: stg_<source>__<table>",
    "intermediate_naming_convention": "Intermediate: int_<subject>__<verb>",
    "marts_naming_convention": "Marts: dim_*, fct_*, kpi_*",
    "no_special_characters": "No spaces or special characters",
    "uses_ref_not_hardcoded": "Uses {{ ref() }} not hardcoded tables",
    "uses_source_in_staging": "Uses {{ source() }} in staging only",
    "no_cross_db_refs": "No cross-database refs without config",
    "appropriate_materialization": "Appropriate materialization chosen",
    "staging_models_are_views": "Staging models are views",
    "mart_models_are_tables": "Mart models are tables",
    "incremental_where_appropriate": "Incremental where appropriate",
    "config_block_at_top": "Config block at top of model",
    "tags_for_categorization": "Tags for categorization",
    "schema_override_where_needed": "Schema override where needed",
    "grants_configured": "Grants configured",
    "pre_hooks_cleanup": "Pre-hooks for cleanup",
    "post_hooks_grants": "Post-hooks for grants",
    "post_hooks_indexes": "Post-hooks for indexes",
    "hooks_use_this": "Hooks use {{ this }}",

    # Category 6: SQL Pattern Sophistication (25 criteria)
    "row_number_dedup": "ROW_NUMBER for deduplication",
    "rank_dense_rank": "RANK/DENSE_RANK for ranking",
    "lag_lead_comparisons": "LAG/LEAD for comparisons",
    "running_totals": "Running totals (SUM OVER)",
    "moving_averages": "Moving averages (ROWS BETWEEN)",
    "first_last_value": "FIRST_VALUE/LAST_VALUE",
    "ntile_percent_rank": "NTILE/PERCENT_RANK",
    "qualify_clause": "QUALIFY clause",
    "recursive_cte": "Recursive CTE",
    "grouping_sets": "GROUPING SETS/CUBE/ROLLUP",
    "pivot_unpivot": "PIVOT/UNPIVOT",
    "lateral_join": "LATERAL JOIN",
    "array_operations": "ARRAY operations (ARRAY_AGG, UNNEST)",
    "json_operations": "JSON operations",
    "set_operations": "Set operations (EXCEPT, INTERSECT)",
    "filter_clause": "FILTER clause",
    "within_group": "WITHIN GROUP",
    "self_join_constraint": "Self-join with < constraint",
    "anti_join": "Anti-join (LEFT JOIN + IS NULL)",
    "semi_join": "Semi-join (WHERE EXISTS)",
    "correlated_subquery": "Correlated subquery",
    "conditional_aggregation": "Conditional aggregation (CASE in agg)",
    "multiple_granularity": "Multiple granularity (GROUPING SETS)",
    "distinct_count_optimization": "Distinct count optimization",
    "string_aggregation": "String aggregation",

    # Category 7: Jinja Pattern Usage (19 criteria)
    "jinja_conditionals": "Conditionals ({% if %})",
    "jinja_loops": "Loops ({% for %})",
    "jinja_variable_assignment": "Variable assignment ({% set %})",
    "loop_metadata": "Loop metadata (loop.index, loop.last)",
    "execute_blocks": "Execute blocks ({% do %})",
    "dynamic_column_selection": "Dynamic column selection",
    "dynamic_pivot": "Dynamic pivot",
    "union_multiple_sources": "Union multiple sources",
    "run_query_dynamic": "run_query for dynamic values",
    "custom_macros": "Custom macros",
    "dbt_utils_macros": "dbt_utils macros",
    "fivetran_utils_macros": "fivetran_utils macros",
    "surrogate_key_generation": "Surrogate key generation",
    "star_select_exclusions": "Star select with exclusions",
    "safe_divide_macro": "Safe divide macro",
    "dbt_date_functions": "Date functions (dbt.dateadd)",
    "dbt_type_functions": "Type functions (dbt.type_timestamp)",
    "dbt_current_timestamp": "Current timestamp (dbt.current_timestamp)",
    "adapter_dispatch": "Adapter dispatch",

    # Category 8: Incremental & Performance (15 criteria)
    "basic_incremental": "Basic incremental",
    "merge_strategy": "Merge strategy",
    "delete_insert_strategy": "Delete+insert strategy",
    "append_strategy": "Append strategy",
    "insert_overwrite_strategy": "Insert overwrite (partitions)",
    "unique_key_defined": "Unique key defined",
    "lookback_window": "Lookback window",
    "on_schema_change": "On schema change handling",
    "incremental_predicates": "Incremental predicates",
    "partitioning": "Partitioning configured",
    "clustering": "Clustering configured",
    "sort_keys": "Sort keys configured",
    "index_creation": "Index creation (post-hook)",
    "early_filtering": "Early filtering (WHERE before JOIN)",
    "selective_column_retrieval": "Selective column retrieval",

    # Category 9: Cross-Database Compatibility (12 criteria)
    "type_string_adapter": "dbt.type_string()",
    "type_numeric_adapter": "dbt.type_numeric()",
    "type_timestamp_adapter": "dbt.type_timestamp()",
    "type_boolean_adapter": "dbt.type_boolean()",
    "type_float_adapter": "dbt.type_float()",
    "dateadd_adapter": "dbt.dateadd()",
    "datediff_adapter": "dbt.datediff()",
    "date_trunc_adapter": "dbt.date_trunc()",
    "explicit_cast": "Explicit CAST statements",
    "safe_casting": "Safe casting (TRY_CAST)",
    "adapter_dispatch_macros": "Adapter dispatch macros",
    "target_conditionals": "Target conditionals",

    # Category 10: Configuration & Feature Flags (10 criteria)
    "enabled_disabled_flag": "Enabled/disabled flag",
    "date_range_filtering": "Date range filtering",
    "row_limit_for_dev": "Row limit for dev",
    "environment_specific_logic": "Environment-specific logic",
    "default_values_vars": "Default values provided for vars",
    "variables_documented": "Variables documented",
    "meaningful_variable_names": "Meaningful variable names",
    "variables_for_business_rules": "Variables for business rules",
    "execute_for_queries": "{% if execute %} for queries",
    "fallbacks_compile_mode": "Fallbacks for compile mode",

    # Category 11: Error Handling & Edge Cases (15 criteria)
    "coalesce_defaults": "COALESCE for defaults",
    "nullif_create_nulls": "NULLIF to create NULLs",
    "null_checks_where": "NULL checks in WHERE",
    "null_safe_comparisons": "NULL-safe comparisons",
    "empty_string_to_null": "Empty string to NULL",
    "trim_before_comparison": "Trim before comparison",
    "length_checks": "Length checks",
    "test_data_exclusion": "Test data exclusion",
    "placeholder_filtering": "Placeholder filtering",
    "format_validation": "Format validation",
    "range_validation": "Range validation",
    "division_by_zero_check": "Division by zero check",
    "safe_divide_check": "Safe divide macro used",
    "invalid_date_handling": "Invalid date handling",
    "future_date_filtering": "Future date filtering",

    # Category 12: Model Architecture (12 criteria)
    "layer_adherence": "Sources → Staging → Intermediate → Marts",
    "staging_minimal_transform": "Staging does minimal transformation",
    "business_logic_intermediate": "Business logic in intermediate",
    "marts_business_ready": "Marts are business-ready",
    "staging_no_ref_other_staging": "Staging doesn't reference other staging",
    "intermediate_refs_staging": "Intermediate references staging/int",
    "marts_ref_intermediate": "Marts reference intermediate",
    "no_circular_dependencies": "No circular dependencies",
    "one_entity_per_model": "One entity per model",
    "grain_documented": "Clear grain documented",
    "dimensions_denormalized": "Dimensions are denormalized",
    "facts_contain_measures": "Facts contain measures",

    # Category 13: Dependency Management (10 criteria)
    "all_refs_use_ref": "All refs use {{ ref() }}",
    "source_freshness_defined": "Source freshness defined",
    "dependencies_documented": "Dependencies documented",
    "low_fan_in": "Low fan-in (1-3 refs)",
    "fan_out_documented": "Fan-out documented",
    "dag_no_circular": "No circular dependencies in DAG",
    "reasonable_dag_depth": "Reasonable DAG depth",
    "critical_path_identified": "Critical path identified",
    "source_relation_joins": "source_relation on all joins",
    "tenant_id_surrogate": "Tenant ID in surrogate keys",

    # Category 14: Anti-patterns (avoided) (7 criteria)
    "no_select_star": "No SELECT * usage",
    "no_cartesian_join": "No cartesian join risk",
    "no_not_in_nulls": "No NOT IN with NULLs",
    "no_like_prefix_wildcard": "No LIKE '%prefix'",
    "no_functions_where_columns": "No functions in WHERE on columns",
    "no_order_subquery": "No ORDER BY in subquery",
    "no_distinct_many_columns": "No DISTINCT on many columns",

    # Category 16: Human-Created Realism (35 criteria)
    "multiple_coding_styles": "Multiple coding styles across models",
    "author_variety": "Author attribution variety (5-10 different)",
    "date_range_creation": "Date range of creation (multiple years)",
    "team_attribution": "Team attribution markers",
    "departed_employee_markers": "Departed employee markers",
    "mixed_indentation": "Mixed indentation (tabs AND spaces)",
    "trailing_comma_variance": "Trailing comma variance",
    "keyword_case_variance": "Keyword case variance (SELECT and select)",
    "line_length_variance": "Line length variance",
    "blank_line_variance": "Blank line variance",
    "quote_style_variance": "Quote style variance",
    "todo_with_dates": "TODO/FIXME with dates",
    "multi_year_history": "Multi-year modification history",
    "incident_history_comments": "Incident history comments",
    "wtf_confusion_comments": "WTF/confusion comments",
    "deprecated_warnings": "Deprecated warnings",
    "performance_notes_comments": "Performance notes in comments",
    "variable_documentation_coverage": "Variable documentation coverage",
    "outdated_docs_exist": "Outdated docs exist",
    "missing_schema_entries": "Some models undocumented",
    "todo_without_resolution": "TODO without resolution",
    "hack_comments": "HACK comments",
    "commented_out_code": "Commented-out code",
    "temporary_filters": "Temporary filters",
    "copy_paste_artifacts": "Copy-paste artifacts",
    "mixed_naming_patterns": "Mixed naming patterns",
    "version_suffixes": "Version suffixes (_v1, _v2)",
    "date_stamped_models": "Date-stamped models",
    "temporary_model_names": "Temporary models (tmp_, test_)",
    "legacy_prefixes": "Legacy prefixes (legacy_, old_)",
    "archive_folder_exists": "Archive folder with models",
    "deprecated_models_exist": "Deprecated models (not deleted)",
    "wip_draft_models": "WIP/Draft models",
    "debug_analysis_models": "Debug/Analysis models",
    "disabled_models_reason": "Disabled models with reason",

    # Additional Human Realism Criteria
    "code_review_thread": "Code review discussion thread",
    "known_issues_section": "Known issues section",
    "stakeholder_names": "Stakeholder names mentioned",
    "self_deprecating": "Self-deprecating comments",
    "team_debate": "Team debate/disagreement in comments",
    "rich_meta_config": "Rich meta config (owner, SLA, etc)",
    "downstream_consumers": "Downstream consumers documented",
    "debug_queries": "Debug queries (commented out)",
    "inline_explanations": "Inline explanations in code",
    "temporal_references": "Temporal references (Q2 2023, etc)",

    # Category 17: Enterprise Scale (11 criteria)
    "passing_models_95pct": "Passing models >95%",
    "disabled_with_reason": "Disabled with reason (1-5%)",
    "archive_deprecated_present": "Archive/deprecated present",
    "mix_simple_complex": "Mix of simple and complex queries",
    "snowflake_workarounds": "DB-specific workarounds",
    "currency_symbol_handling": "Currency symbol handling",
    "case_sensitivity_handling": "Case sensitivity handling",
    "models_compile_successfully": "Models compile successfully",
    "models_execute_without_error": "Models execute without error",
    "tests_pass": "Tests pass",
    "docs_generate": "Docs generate",
}

TOTAL_CRITERIA = len(CRITERIA)

# =============================================================================
# BIMODAL GAUSSIAN SAMPLER
# =============================================================================

def sample_bimodal_gaussian(peak1: int = 50, peak2: int = 150,
                            sigma1: float = 20, sigma2: float = 25,
                            weight1: float = 0.4) -> int:
    """
    Sample from bimodal Gaussian distribution.

    Args:
        peak1: Center of first Gaussian (sparse models)
        peak2: Center of second Gaussian (heavy models)
        sigma1: Std dev of first Gaussian
        sigma2: Std dev of second Gaussian
        weight1: Probability of sampling from first Gaussian (0-1)

    Returns:
        Number of criteria to apply (clamped to valid range)
    """
    if random.random() < weight1:
        # Sample from first peak (sparse documentation)
        sample = np.random.normal(peak1, sigma1)
    else:
        # Sample from second peak (heavy documentation)
        sample = np.random.normal(peak2, sigma2)

    # Clamp to valid range
    return max(5, min(int(round(sample)), TOTAL_CRITERIA))


def sample_criteria_for_model(model_name: str) -> Dict:
    """Sample random criteria for a model using bimodal Gaussian."""
    num_criteria = sample_bimodal_gaussian()
    all_keys = list(CRITERIA.keys())
    selected_keys = random.sample(all_keys, min(num_criteria, len(all_keys)))

    return {
        "model": model_name,
        "num_criteria": num_criteria,
        "pct_criteria": round(100 * num_criteria / TOTAL_CRITERIA, 1),
        "selected": selected_keys,
    }


def print_distribution_analysis(n_samples: int = 500):
    """Print distribution analysis."""
    counts = [sample_bimodal_gaussian() for _ in range(n_samples)]

    print("=" * 70)
    print(f"BIMODAL GAUSSIAN DISTRIBUTION (peaks at 50 and 150)")
    print(f"Total criteria: {TOTAL_CRITERIA}")
    print("=" * 70)
    print()
    print(f"Samples: {n_samples}")
    print(f"Mean: {np.mean(counts):.1f} criteria ({100*np.mean(counts)/TOTAL_CRITERIA:.1f}%)")
    print(f"Median: {np.median(counts):.0f} criteria")
    print(f"Std Dev: {np.std(counts):.1f}")
    print(f"Min/Max: {min(counts)}-{max(counts)}")
    print()

    # Histogram buckets
    buckets = [(0, 40), (40, 80), (80, 120), (120, 160), (160, 210)]
    print("Distribution:")
    for low, high in buckets:
        count = sum(1 for c in counts if low <= c < high)
        bar = "█" * (count * 40 // n_samples)
        print(f"  {low:3d}-{high:3d}: {count:3d} ({100*count/n_samples:5.1f}%) {bar}")
    print()


def main():
    """Demo the criteria selection."""
    random.seed(42)
    np.random.seed(42)

    print_distribution_analysis(n_samples=500)

    # Models to update
    models = [
        "stg_analytics__dim_customer.sql",
        "stg_orders__orders.sql",
        "rpt_campaign_roi_analysis.sql",
        "fct_promotion_profitability.sql",
        "rpt_customer_loyalty_balance.sql",
        "ts_customers__new_customers_weekly.sql",
    ]

    print("=" * 70)
    print("MODEL CRITERIA ASSIGNMENTS")
    print("=" * 70)
    print()

    for m in models:
        result = sample_criteria_for_model(m)
        tier = "🔥 HEAVY" if result["num_criteria"] > 120 else "📄 MEDIUM" if result["num_criteria"] > 70 else "⚡ SPARSE"
        print(f"{tier} {result['model']}")
        print(f"     {result['num_criteria']} / {TOTAL_CRITERIA} criteria ({result['pct_criteria']}%)")
        print(f"     First 10: {result['selected'][:10]}")
        print()


if __name__ == "__main__":
    main()
