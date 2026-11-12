"""Regression checks for nullable suppliers outside source-comparison scope."""

import runpy
from pathlib import Path
from unittest.mock import patch

import pytest

TASK = Path(__file__).resolve().parents[1] / "tasks" / "dbt-supplier-scorecard"
COMPARISONS = [
    (
        "test_on_time_delivery_rate_matches_source",
        {4: 2, 5: 1, 6: 50.0},
        {"total_pos": 2, "on_time_pos": 1, "on_time_delivery_rate": 50.0},
    ),
    (
        "test_acceptance_rate_matches_source",
        {8: 10, 9: 9, 11: 90.0},
        {"total_received": 10, "total_accepted": 9, "acceptance_rate": 90.0},
    ),
    (
        "test_cost_variance_matches_source",
        {13: 100.0, 14: 90.0, 16: -10.0},
        {
            "total_po_value": 100.0,
            "total_invoice_value": 90.0,
            "cost_variance_pct": -10.0,
        },
    ),
]


@pytest.fixture(params=COMPARISONS, ids=[item[0] for item in COMPARISONS])
def comparison(request):
    with patch("os.path.exists", return_value=False):
        module = runpy.run_path(str(TASK / "tests" / "test_outputs.py"))
    method_name, values, expected = request.param
    instance = module["TestPhase4SourceValidation"]()
    row = [None] * 17
    row[:2] = ["supplier", "SUP0001"]
    for index, value in values.items():
        row[index] = value
    return getattr(instance, method_name), row, expected, next(iter(values))


def test_out_of_scope_null_supplier_does_not_crash(comparison):
    check, row, expected, _ = comparison
    out_of_scope = ["without-source", "SUP0008"] + [None] * 15
    check([out_of_scope, row], {"supplier": expected})


def test_in_scope_matching_supplier_still_passes(comparison):
    check, row, expected, _ = comparison
    check([row], {"supplier": expected})


def test_in_scope_mismatch_still_fails(comparison):
    check, row, expected, index = comparison
    row[index] += 100
    with pytest.raises(AssertionError, match="don't match source"):
        check([row], {"supplier": expected})


def test_in_scope_null_is_not_silently_zero_filled(comparison):
    check, row, expected, index = comparison
    row[index] = None
    with pytest.raises(TypeError):
        check([row], {"supplier": expected})
