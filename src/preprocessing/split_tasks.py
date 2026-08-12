#!/usr/bin/env python3
"""Create deterministic category-stratified train and test task lists."""

from __future__ import annotations

import argparse
import random
import sys
import tomllib
from collections import Counter, defaultdict
from pathlib import Path


TEST_ONLY_CATEGORIES = {"dbt", "dbt-snapshots", "finance"}
TRAIN_RATIOS = {
    "debugging": 0.5,
}
DEFAULT_TRAIN_RATIO = 0.7


def parse_args() -> argparse.Namespace:
    project_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Split task directories into category-stratified train/test lists."
    )
    parser.add_argument(
        "--tasks-dir",
        type=Path,
        default=project_root / "tasks",
        help="Directory containing one subdirectory per task (default: %(default)s)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=project_root / "splits",
        help="Directory for train.txt and test.txt (default: %(default)s)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed used within each category (default: %(default)s)",
    )
    return parser.parse_args()


def load_tasks(tasks_dir: Path) -> dict[str, str]:
    if not tasks_dir.is_dir():
        raise ValueError(f"Tasks directory does not exist: {tasks_dir}")

    tasks: dict[str, str] = {}
    for task_dir in sorted(path for path in tasks_dir.iterdir() if path.is_dir()):
        metadata_path = task_dir / "task.toml"
        if not metadata_path.is_file():
            raise ValueError(f"Missing task.toml: {metadata_path}")

        with metadata_path.open("rb") as file:
            metadata = tomllib.load(file).get("metadata", {})
        category = metadata.get("category")
        if not isinstance(category, str) or not category:
            raise ValueError(f"Missing metadata.category: {metadata_path}")
        tasks[task_dir.name] = category

    if not tasks:
        raise ValueError(f"No task directories found in: {tasks_dir}")
    return tasks


def split_tasks(tasks: dict[str, str], seed: int) -> tuple[list[str], list[str]]:
    by_category: dict[str, list[str]] = defaultdict(list)
    for task_name, category in tasks.items():
        by_category[category].append(task_name)

    train: list[str] = []
    test: list[str] = []
    for category in sorted(by_category):
        category_tasks = sorted(by_category[category])
        random.Random(f"{seed}:{category}").shuffle(category_tasks)

        if category in TEST_ONLY_CATEGORIES:
            train_count = 0
        else:
            ratio = TRAIN_RATIOS.get(category, DEFAULT_TRAIN_RATIO)
            train_count = round(len(category_tasks) * ratio)

        train.extend(category_tasks[:train_count])
        test.extend(category_tasks[train_count:])

    train.sort()
    test.sort()
    validate_split(tasks, train, test)
    return train, test


def validate_split(tasks: dict[str, str], train: list[str], test: list[str]) -> None:
    train_set = set(train)
    test_set = set(test)
    if len(train_set) != len(train) or len(test_set) != len(test):
        raise ValueError("Duplicate task found within a split")
    if overlap := train_set & test_set:
        raise ValueError(f"Tasks appear in both splits: {sorted(overlap)}")
    if train_set | test_set != tasks.keys():
        missing = sorted(tasks.keys() - train_set - test_set)
        extra = sorted(train_set | test_set - tasks.keys())
        raise ValueError(f"Invalid task coverage; missing={missing}, extra={extra}")
    if misplaced := sorted(
        task for task in train if tasks[task] in TEST_ONLY_CATEGORIES
    ):
        raise ValueError(f"Test-only category tasks found in train: {misplaced}")


def write_split(output_dir: Path, train: list[str], test: list[str]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "train.txt").write_text("\n".join(train) + "\n", encoding="utf-8")
    (output_dir / "test.txt").write_text("\n".join(test) + "\n", encoding="utf-8")


def print_summary(tasks: dict[str, str], train: list[str], test: list[str]) -> None:
    train_counts = Counter(tasks[task] for task in train)
    test_counts = Counter(tasks[task] for task in test)

    print(f"{'category':<20} {'train':>5} {'test':>5} {'total':>5}")
    for category in sorted(set(tasks.values())):
        train_count = train_counts[category]
        test_count = test_counts[category]
        print(
            f"{category:<20} {train_count:>5} {test_count:>5} "
            f"{train_count + test_count:>5}"
        )
    print(f"{'TOTAL':<20} {len(train):>5} {len(test):>5} {len(tasks):>5}")


def main() -> int:
    args = parse_args()
    try:
        tasks = load_tasks(args.tasks_dir)
        train, test = split_tasks(tasks, args.seed)
        write_split(args.output_dir, train, test)
    except (OSError, ValueError, tomllib.TOMLDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print_summary(tasks, train, test)
    print(f"Wrote {args.output_dir / 'train.txt'}")
    print(f"Wrote {args.output_dir / 'test.txt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
