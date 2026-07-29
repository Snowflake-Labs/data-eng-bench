#!/usr/bin/env python3
"""
Randomize Realism Criteria Selector

Uses lognormal distribution to select which human-created realism
criteria to apply to each dbt model. This creates realistic variation
where most models get few enhancements and some get many.

Lognormal distribution properties:
- Mean (mu) = 1.0, Sigma = 0.8
- Most samples: 1-3 criteria (rushed developer)
- Some samples: 4-6 criteria (average developer)
- Few samples: 7+ criteria (senior engineer / critical model)
"""

import numpy as np
import random
from typing import List, Dict

# All possible human-created realism criteria
REALISM_CRITERIA = {
    # Documentation patterns
    "author_attribution": "Add @author tag with name, team, date",
    "code_review_thread": "Add multi-person code review discussion",
    "known_issues_section": "Document known issues with ticket refs",
    "version_history": "Add version history (v1, v2, changes)",
    "business_context": "Explain business purpose and stakeholders",
    "performance_notes": "Add runtime estimates and optimization notes",

    # Comment patterns
    "todo_comments": "Add TODO with ticket reference",
    "fixme_comments": "Add FIXME for known bugs",
    "hack_comments": "Add HACK explaining workarounds",
    "debug_queries": "Add commented-out debug SQL",
    "inline_explanations": "Add inline comments explaining logic",

    # Config patterns
    "rich_meta_config": "Add meta block with owner, SLA, etc",
    "extra_tags": "Add descriptive tags beyond basic",
    "downstream_consumers": "Document who uses this model",

    # Formatting patterns (intentional inconsistency)
    "mixed_case_keywords": "Mix UPPERCASE and lowercase SQL keywords",
    "inconsistent_aliases": "Mix AS vs as, trailing commas",
    "section_headers": "Add === section headers in long models",

    # Human touch patterns
    "self_deprecating": "Add self-deprecating or frustrated comments",
    "team_debate": "Show disagreement/discussion in comments",
    "temporal_references": "Reference quarters, years, incidents by date",
    "stakeholder_names": "Mention real stakeholder names (Julie, Tom, etc)",
}

def sample_criteria_count(mu: float = 1.0, sigma: float = 0.8, max_criteria: int = None) -> int:
    """
    Sample number of criteria using lognormal distribution.

    Lognormal gives us:
    - Mode around 2-3 (most common)
    - Long tail up to 10+ (rare but possible)
    """
    if max_criteria is None:
        max_criteria = len(REALISM_CRITERIA)

    # Lognormal sample, clamped to valid range
    sample = np.random.lognormal(mean=mu, sigma=sigma)
    count = int(round(sample))
    return max(1, min(count, max_criteria))

def select_criteria_for_model(model_type: str = "staging") -> Dict[str, str]:
    """
    Select random subset of criteria based on lognormal distribution.

    Model type affects base probability:
    - staging: fewer criteria (simpler models)
    - intermediate: medium criteria
    - marts: more criteria (business-facing)
    """
    # Adjust distribution parameters by model type
    params = {
        "staging": {"mu": 0.8, "sigma": 0.7},      # Simpler, less documentation
        "intermediate": {"mu": 1.0, "sigma": 0.8}, # Medium complexity
        "marts": {"mu": 1.2, "sigma": 0.9},        # More documentation expected
        "data_quality": {"mu": 1.5, "sigma": 0.6}, # Usually well-documented
    }

    p = params.get(model_type, params["intermediate"])
    num_criteria = sample_criteria_count(mu=p["mu"], sigma=p["sigma"])

    # Randomly select criteria
    all_criteria = list(REALISM_CRITERIA.keys())
    selected_keys = random.sample(all_criteria, min(num_criteria, len(all_criteria)))

    return {k: REALISM_CRITERIA[k] for k in selected_keys}

def generate_model_criteria_assignments(models: List[Dict]) -> List[Dict]:
    """
    Generate criteria assignments for a list of models.

    Returns list of dicts with model info and selected criteria.
    """
    results = []

    for model in models:
        criteria = select_criteria_for_model(model.get("type", "intermediate"))
        results.append({
            "model": model["name"],
            "type": model.get("type", "intermediate"),
            "num_criteria": len(criteria),
            "selected_criteria": list(criteria.keys()),
            "criteria_descriptions": criteria
        })

    return results

def print_distribution_sample(n_samples: int = 20):
    """Print sample distribution to verify lognormal behavior."""
    print("=" * 60)
    print("LOGNORMAL CRITERIA SAMPLING DISTRIBUTION")
    print("=" * 60)
    print()

    for model_type in ["staging", "intermediate", "marts"]:
        counts = [len(select_criteria_for_model(model_type)) for _ in range(100)]
        print(f"{model_type.upper()}:")
        print(f"  Mean: {np.mean(counts):.1f} criteria")
        print(f"  Median: {np.median(counts):.0f} criteria")
        print(f"  Min/Max: {min(counts)}-{max(counts)} criteria")
        print(f"  Distribution: {dict(sorted([(c, counts.count(c)) for c in set(counts)]))}")
        print()

def main():
    """Demo the criteria selection."""
    np.random.seed(42)  # For reproducibility in demo
    random.seed(42)

    print_distribution_sample()

    # Example models to update
    models = [
        {"name": "stg_analytics__dim_customer.sql", "type": "staging"},
        {"name": "stg_orders__orders.sql", "type": "staging"},
        {"name": "rpt_campaign_roi_analysis.sql", "type": "marts"},
        {"name": "fct_promotion_profitability.sql", "type": "marts"},
        {"name": "rpt_customer_loyalty_balance.sql", "type": "marts"},
        {"name": "ts_customers__new_customers_weekly.sql", "type": "marts"},
    ]

    print("=" * 60)
    print("CRITERIA ASSIGNMENTS FOR MODELS")
    print("=" * 60)
    print()

    assignments = generate_model_criteria_assignments(models)

    for a in assignments:
        print(f"📄 {a['model']}")
        print(f"   Type: {a['type']}")
        print(f"   Criteria count: {a['num_criteria']}")
        print(f"   Selected: {a['selected_criteria']}")
        print()

if __name__ == "__main__":
    main()
