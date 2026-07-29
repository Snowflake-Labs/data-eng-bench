#!/usr/bin/env python3
"""
Imbalanced Criteria Sampler for dbt Model Realism

Distribution:
- 10% of models → >90% criteria (senior engineer, critical models)
- 10% of models → ~30% criteria (rushed developer, minimal)
- 80% of models → balanced 40-80% (typical developer)

Uses mixture model to achieve this distribution.
"""

import numpy as np
import random
from typing import List, Dict, Tuple
from dataclasses import dataclass

# =============================================================================
# ALL CRITERIA FROM DBT_MODEL_QUALITY_METRICS.md (130+ criteria)
# =============================================================================

CRITERIA = {
    # Category 1: Code Quality & Style (8%)
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

    # Category 2: Documentation (8%)
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
    "model_level_description": "Model-level description in schema.yml",
    "all_columns_documented": "All columns documented in schema.yml",
    "doc_blocks_used": "Doc blocks used ({{ doc() }})",
    "column_descriptions_meaningful": "Column descriptions meaningful",
    "examples_provided": "Examples provided where helpful",
    "schedule_frequency_noted": "Schedule/frequency noted",
    "performance_characteristics": "Performance characteristics documented",
    "alert_thresholds_documented": "Alert thresholds documented",
    "data_owner_specified": "Data owner specified",

    # Category 3: Testing Strategy (7%)
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

    # Category 4: Maintainability (6%)
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

    # Category 5: dbt Best Practices (7%)
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

    # Category 6: SQL Pattern Sophistication (8%)
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

    # Category 7: Jinja Pattern Usage (7%)
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

    # Category 8-11: Performance, Cross-DB, Config, Error Handling
    "basic_incremental": "Basic incremental",
    "merge_strategy": "Merge strategy",
    "delete_insert_strategy": "Delete+insert strategy",
    "unique_key_defined": "Unique key defined",
    "lookback_window": "Lookback window",
    "on_schema_change": "On schema change handling",
    "partitioning": "Partitioning configured",
    "clustering": "Clustering configured",
    "early_filtering": "Early filtering (WHERE before JOIN)",
    "coalesce_defaults": "COALESCE for defaults",
    "nullif_create_nulls": "NULLIF to create NULLs",
    "null_safe_comparisons": "NULL-safe comparisons",
    "empty_string_to_null": "Empty string to NULL",
    "test_data_exclusion": "Test data exclusion",
    "division_by_zero_check": "Division by zero check",

    # Category 12-15: Architecture, Dependencies, Anti-patterns, Length
    "layer_adherence": "Sources → Staging → Intermediate → Marts",
    "staging_minimal_transform": "Staging does minimal transformation",
    "business_logic_intermediate": "Business logic in intermediate",
    "marts_business_ready": "Marts are business-ready",
    "no_circular_dependencies": "No circular dependencies",
    "one_entity_per_model": "One entity per model",
    "grain_documented": "Clear grain documented",
    "dimensions_denormalized": "Dimensions are denormalized",
    "facts_contain_measures": "Facts contain measures",
    "surrogate_keys_used": "Surrogate keys used",

    # Category 16: Human-Created Realism (CRITICAL - 12%)
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
    "variable_documentation_coverage": "Variable documentation coverage (realistic mix)",
    "outdated_docs_exist": "Outdated docs exist",
    "missing_schema_entries": "Some models undocumented (realistic)",
    "todo_without_resolution": "TODO without resolution",
    "hack_comments": "HACK comments",
    "commented_out_code": "Commented-out code",
    "temporary_filters": "Temporary filters",
    "copy_paste_artifacts": "Copy-paste artifacts",
    "mixed_naming_patterns": "Mixed naming patterns (snake AND UPPER)",
    "version_suffixes": "Version suffixes (_v1, _v2, _FINAL)",
    "date_stamped_models": "Date-stamped models",
    "temporary_model_names": "Temporary models (tmp_, test_)",
    "legacy_prefixes": "Legacy prefixes (legacy_, old_)",
    "archive_folder_exists": "Archive folder with models",
    "deprecated_models_exist": "Deprecated models (not deleted)",
    "wip_draft_models": "WIP/Draft models",
    "debug_analysis_models": "Debug/Analysis models",
    "disabled_models_reason": "Disabled models with reason",

    # Category 17: Enterprise Scale
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
print(f"Total criteria: {TOTAL_CRITERIA}")

# =============================================================================
# IMBALANCED DISTRIBUTION SAMPLER
# =============================================================================

def sample_criteria_count_imbalanced() -> int:
    """
    Sample number of criteria using imbalanced distribution:
    - 10% → >90% criteria (high documentation)
    - 10% → ~30% criteria (minimal)
    - 80% → 40-80% (balanced middle)
    """
    roll = random.random()

    if roll < 0.10:
        # Bottom 10%: ~30% of criteria (minimal documentation)
        pct = random.uniform(0.20, 0.35)
    elif roll < 0.20:
        # Top 10%: >90% of criteria (heavy documentation)
        pct = random.uniform(0.90, 1.0)
    else:
        # Middle 80%: 40-80% (balanced)
        pct = random.uniform(0.40, 0.80)

    return max(1, int(pct * TOTAL_CRITERIA))


def sample_criteria_for_model(model_name: str, model_type: str = "marts") -> Dict:
    """
    Sample random criteria for a model using imbalanced distribution.
    """
    num_criteria = sample_criteria_count_imbalanced()
    all_keys = list(CRITERIA.keys())
    selected_keys = random.sample(all_keys, min(num_criteria, len(all_keys)))

    return {
        "model": model_name,
        "type": model_type,
        "num_criteria": num_criteria,
        "pct_criteria": round(100 * num_criteria / TOTAL_CRITERIA, 1),
        "selected": selected_keys,
        "selected_descriptions": {k: CRITERIA[k] for k in selected_keys}
    }


def print_distribution_analysis(n_samples: int = 100):
    """Print distribution analysis."""
    counts = [sample_criteria_count_imbalanced() for _ in range(n_samples)]
    pcts = [100 * c / TOTAL_CRITERIA for c in counts]

    print("=" * 70)
    print("IMBALANCED DISTRIBUTION ANALYSIS")
    print("=" * 70)
    print(f"\nTotal criteria available: {TOTAL_CRITERIA}")
    print(f"Samples: {n_samples}")
    print()
    print(f"Mean criteria: {np.mean(counts):.1f} ({np.mean(pcts):.1f}%)")
    print(f"Median criteria: {np.median(counts):.0f} ({np.median(pcts):.1f}%)")
    print(f"Min/Max: {min(counts)}-{max(counts)} ({min(pcts):.0f}%-{max(pcts):.0f}%)")
    print()

    # Bucket analysis
    low = sum(1 for p in pcts if p <= 35)
    mid = sum(1 for p in pcts if 35 < p <= 85)
    high = sum(1 for p in pcts if p > 85)

    print("Distribution buckets:")
    print(f"  ≤35% criteria (minimal):     {low:3d} ({100*low/n_samples:.0f}%) - target: 10%")
    print(f"  36-85% criteria (balanced):  {mid:3d} ({100*mid/n_samples:.0f}%) - target: 80%")
    print(f"  >85% criteria (full):        {high:3d} ({100*high/n_samples:.0f}%) - target: 10%")
    print()


def main():
    """Demo the criteria selection."""
    np.random.seed(None)  # Random seed each run
    random.seed(None)

    print_distribution_analysis(n_samples=100)

    # Example models
    models = [
        ("stg_analytics__dim_customer.sql", "staging"),
        ("stg_orders__orders.sql", "staging"),
        ("rpt_campaign_roi_analysis.sql", "marts"),
        ("fct_promotion_profitability.sql", "marts"),
        ("rpt_customer_loyalty_balance.sql", "marts"),
        ("ts_customers__new_customers_weekly.sql", "marts"),
    ]

    print("=" * 70)
    print("CRITERIA ASSIGNMENTS FOR MODELS")
    print("=" * 70)
    print()

    for name, mtype in models:
        result = sample_criteria_for_model(name, mtype)
        tier = "🔥 FULL" if result["pct_criteria"] > 85 else "📄 MEDIUM" if result["pct_criteria"] > 35 else "⚡ MINIMAL"
        print(f"{tier} {result['model']}")
        print(f"     {result['num_criteria']} criteria ({result['pct_criteria']}%)")
        print(f"     Sample: {result['selected'][:5]}...")
        print()


if __name__ == "__main__":
    main()
