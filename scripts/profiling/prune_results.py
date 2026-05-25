#!/usr/bin/env python3
"""
prune_results.py — apply the retention curve to a prof-results/ tree.

Run this script manually after parse_results.py has been run (so that
summary.json files exist in each leaf before pruning):

    In CI (after parse_results.py):
        python3 scripts/profiling/prune_results.py --results-dir prof-results --dry-run
        python3 scripts/profiling/prune_results.py --results-dir prof-results --apply

    Locally (from the repo root):
        python3 scripts/profiling/prune_results.py --results-dir prof-results --dry-run

Pruning deletes RAW artifacts (valgrind_profiling.log, valgrind.log,
callgrind_report.txt) for runs that fall outside the retention curve.
Derived files (summary.json, full.json) are NEVER touched. A `.pruned`
marker is written to the leaf so subsequent parse_results.py runs skip
re-parsing that leaf.

Expected tree layout:
    <results-dir>/<branch>/<sha>/<run-number>/<test-suite>/<test-name>/
        summary.json          (required — written by parse_results.py)
        valgrind_profiling.log
        valgrind.log
        callgrind_report.txt

Retention tiers (UTC, age relative to --now):
    Tier 0   0-30 days        keep all raw
    Tier 1   30-60 days       keep half (even indices within each day)
    Tier 2   60-90 days       keep last-of-day only
    Tier 3   90 days-1 year   keep last-of-day on Sun + Wed only
    Tier 4   1+ year          keep last-of-month only

Runs listed in pins.json are exempt.

Usage:
    python3 prune_results.py --results-dir prof-results --dry-run
    python3 prune_results.py --results-dir prof-results --apply

The pruner is idempotent — runs with a `.pruned` marker are skipped.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from pathlib import Path

RAW_FILES = ("valgrind_profiling.log", "valgrind.log", "callgrind_report.txt")
SUMMARY_FILE = "summary.json"
PRUNED_MARKER = ".pruned"
PINS_FILE = "pins.json"


# ---------------------------------------------------------------------------
# Run discovery
# ---------------------------------------------------------------------------

@dataclass
class RunLeaf:
    """A single run leaf on disk: path, timestamp, scope."""
    path: Path                  # absolute path to the leaf directory
    relative_path: str          # path relative to results_dir (matches summary.json's path field)
    test_suite: str
    test_name: str
    branch: str
    sha: str
    run_number: int
    timestamp_iso: str | None   # from summary.json
    timestamp_utc: datetime | None  # parsed
    has_raw: bool
    is_pinned: bool = False

    @property
    def scope(self) -> str:
        return f"{self.test_suite}::{self.branch}"

    @property
    def day_utc(self) -> str | None:
        """YYYY-MM-DD in UTC."""
        if self.timestamp_utc is None:
            return None
        return self.timestamp_utc.strftime("%Y-%m-%d")

    @property
    def month_utc(self) -> str | None:
        """YYYY-MM in UTC."""
        if self.timestamp_utc is None:
            return None
        return self.timestamp_utc.strftime("%Y-%m")


def parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


_SKIP_TOP_LEVEL = frozenset({"baselines", "runs", "index.html", ".git", ".DS_Store"})


def discover_runs(results_dir: Path, pins: set[str]) -> list[RunLeaf]:
    """
    Walk results_dir/<branch>/<sha>/<run>/<suite>/<test>/ and produce a
    RunLeaf for each leaf that has a summary.json. Leaves without
    summary.json are skipped (parse_results.py hasn't been run yet).
    """
    runs: list[RunLeaf] = []

    if not results_dir.is_dir():
        print(f"WARN: results directory not found: {results_dir}", file=sys.stderr)
        return runs

    for branch_dir in sorted(results_dir.iterdir()):
        if not branch_dir.is_dir():
            continue
        branch = branch_dir.name
        if branch.startswith(".") or branch in _SKIP_TOP_LEVEL:
            continue

        for sha_dir in sorted(branch_dir.iterdir()):
            if not sha_dir.is_dir():
                continue
            sha = sha_dir.name

            for run_dir in sorted(sha_dir.iterdir(), key=lambda d: int(d.name) if d.name.isdigit() else -1):
                if not run_dir.is_dir():
                    continue
                try:
                    run_number = int(run_dir.name)
                except ValueError:
                    continue

                for ts_dir in sorted(run_dir.iterdir()):
                    if not ts_dir.is_dir():
                        continue
                    for sn_dir in sorted(ts_dir.iterdir()):
                        if not sn_dir.is_dir():
                            continue
                        leaf = sn_dir

                        summary_path = leaf / SUMMARY_FILE
                        if not summary_path.exists():
                            # parse_results.py hasn't been run yet; pruner won't touch this
                            continue

                        try:
                            data = json.loads(summary_path.read_text())
                        except (json.JSONDecodeError, OSError) as e:
                            print(
                                f"WARN: skipping {leaf} — bad summary.json: {e}",
                                file=sys.stderr,
                            )
                            continue

                        ts_iso = data.get("timestamp_iso")
                        ts_dt = parse_iso(ts_iso)

                        relative = f"{branch}/{sha}/{run_number}/{ts_dir.name}/{sn_dir.name}"
                        has_raw = any((leaf / f).exists() for f in RAW_FILES)

                        runs.append(RunLeaf(
                            path=leaf,
                            relative_path=relative,
                            test_suite=ts_dir.name,
                            test_name=sn_dir.name,
                            branch=branch,
                            sha=sha,
                            run_number=run_number,
                            timestamp_iso=ts_iso,
                            timestamp_utc=ts_dt,
                            has_raw=has_raw,
                            is_pinned=(relative in pins),
                        ))

    return runs


def load_pins(results_dir: Path) -> set[str]:
    """Load pins.json: a list of relative paths to runs that must never be pruned."""
    pins_path = results_dir / PINS_FILE
    if not pins_path.exists():
        return set()
    try:
        data = json.loads(pins_path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        print(f"WARN: cannot read {pins_path}: {e}", file=sys.stderr)
        return set()
    if isinstance(data, dict) and "pins" in data:
        return set(data["pins"])
    if isinstance(data, list):
        return set(data)
    print(f"WARN: {pins_path} has unexpected shape; ignoring", file=sys.stderr)
    return set()


# ---------------------------------------------------------------------------
# Retention curve
# ---------------------------------------------------------------------------

def classify_age_days(run: RunLeaf, now: datetime) -> int | None:
    """Whole days from now back to run timestamp. None if no timestamp."""
    if run.timestamp_utc is None:
        return None
    delta = now - run.timestamp_utc
    return delta.days


def decide_keep(runs: list[RunLeaf], now: datetime) -> tuple[set[str], dict]:
    """
    Apply the retention curve. Returns (keep_paths, stats) where:
      keep_paths is a set of relative_path values whose raw should be retained
      stats is a dict of counts per tier for reporting

    Tiers are computed by (scope, day) groups for tiers 0-3, and by
    (scope, month) for tier 4.
    """
    stats = {
        "tier_0_keep_all": 0,
        "tier_1_half": 0,
        "tier_2_last_of_day": 0,
        "tier_3_sun_wed": 0,
        "tier_4_last_of_month": 0,
        "skipped_no_timestamp": 0,
        "pinned": 0,
    }

    # Bucket runs by (scope, day) and (scope, month). A run is in BOTH bucket
    # types but only one tier applies based on its age.
    by_scope_day: dict[tuple[str, str], list[RunLeaf]] = defaultdict(list)
    by_scope_month: dict[tuple[str, str], list[RunLeaf]] = defaultdict(list)
    pinned_paths: set[str] = set()
    no_ts_paths: set[str] = set()

    for r in runs:
        if r.is_pinned:
            pinned_paths.add(r.relative_path)
            stats["pinned"] += 1
            # Pinned runs are still placed in buckets; we just always keep them.
        if r.day_utc is None:
            no_ts_paths.add(r.relative_path)
            stats["skipped_no_timestamp"] += 1
            continue
        by_scope_day[(r.scope, r.day_utc)].append(r)
        by_scope_month[(r.scope, r.month_utc)].append(r)

    # Sort each bucket by timestamp ascending so "last" / "even indices" are
    # well-defined. Equal timestamps fall back to run_number.
    def sort_runs(rs: list[RunLeaf]) -> list[RunLeaf]:
        return sorted(rs, key=lambda r: (r.timestamp_utc, r.run_number))

    keep: set[str] = set(pinned_paths)
    # Always keep runs that lack timestamps — we can't reason about their age.
    keep.update(no_ts_paths)

    # Walk each (scope, day) group and apply tiers 0-3 based on the day's age.
    for (scope, day), bucket in by_scope_day.items():
        bucket = sort_runs(bucket)
        # Use the day itself (00:00 UTC) for age classification — every run
        # within the day shares its tier.
        try:
            day_dt = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        except ValueError:
            # Shouldn't happen; defensive.
            for r in bucket:
                keep.add(r.relative_path)
            continue
        age_days = (now - day_dt).days

        if age_days <= 30:
            # Tier 0: keep all raw
            for r in bucket:
                keep.add(r.relative_path)
                stats["tier_0_keep_all"] += 1
        elif age_days <= 60:
            # Tier 1: keep even indices within the day (0, 2, 4, ...)
            for i, r in enumerate(bucket):
                if i % 2 == 0:
                    keep.add(r.relative_path)
                    stats["tier_1_half"] += 1
        elif age_days <= 90:
            # Tier 2: keep last of day
            if bucket:
                keep.add(bucket[-1].relative_path)
                stats["tier_2_last_of_day"] += 1
        elif age_days <= 365:
            # Tier 3: keep last of day on Sundays (weekday 6) and Wednesdays (2)
            if day_dt.weekday() in (2, 6) and bucket:
                keep.add(bucket[-1].relative_path)
                stats["tier_3_sun_wed"] += 1
        # else: tier 4, handled below per-month

    # Walk each (scope, month) group and handle tier 4 (1+ year old).
    for (scope, month), bucket in by_scope_month.items():
        bucket = sort_runs(bucket)
        try:
            month_dt = datetime.strptime(month, "%Y-%m").replace(tzinfo=timezone.utc)
        except ValueError:
            continue
        age_days = (now - month_dt).days

        if age_days > 365 and bucket:
            # Tier 4: keep last of month
            keep.add(bucket[-1].relative_path)
            stats["tier_4_last_of_month"] += 1

    return keep, stats


# ---------------------------------------------------------------------------
# Action: prune
# ---------------------------------------------------------------------------

def prune_run(run: RunLeaf, dry_run: bool) -> tuple[int, int]:
    """
    Delete raw artifacts for one run leaf.
    Returns (files_deleted, bytes_freed).
    """
    files_deleted = 0
    bytes_freed = 0
    for fname in RAW_FILES:
        p = run.path / fname
        if p.exists():
            try:
                size = p.stat().st_size
            except OSError:
                size = 0
            if not dry_run:
                p.unlink()
            files_deleted += 1
            bytes_freed += size

    # Always write the marker (even on dry-run? no, only on real runs).
    if not dry_run and files_deleted > 0:
        marker = run.path / PRUNED_MARKER
        marker.write_text(json.dumps({
            "pruned_at": datetime.now(timezone.utc).isoformat(),
            "run": run.relative_path,
        }))

    return files_deleted, bytes_freed


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def fmt_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}"
        n /= 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results-dir", type=Path, required=True,
                        help="Path to prof-results directory.")
    parser.add_argument("--now", type=str, default=None,
                        help="ISO 8601 anchor for 'now'. Default: wall-clock UTC.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true",
                      help="Report what would be pruned without deleting anything.")
    mode.add_argument("--apply", action="store_true",
                      help="Actually delete pruned raw artifacts.")
    parser.add_argument("--quiet", action="store_true",
                        help="Suppress per-run output.")
    args = parser.parse_args()

    if args.now:
        anchor = parse_iso(args.now)
        if anchor is None:
            print(f"ERROR: --now {args.now} not parseable as ISO 8601", file=sys.stderr)
            sys.exit(2)
    else:
        anchor = datetime.now(timezone.utc)

    results_dir = args.results_dir.resolve()
    if not results_dir.is_dir():
        print(f"ERROR: --results-dir {results_dir} does not exist", file=sys.stderr)
        sys.exit(2)

    pins = load_pins(results_dir)
    runs = discover_runs(results_dir, pins)

    if not runs:
        print("No runs with summary.json found. Nothing to do.", file=sys.stderr)
        return

    keep_paths, stats = decide_keep(runs, anchor)

    # Drop marker stat — we're going to compute it as we go.
    actually_pruned = 0
    already_pruned = 0
    bytes_freed_total = 0
    files_deleted_total = 0

    for r in runs:
        if r.relative_path in keep_paths:
            continue
        if not r.has_raw:
            already_pruned += 1
            continue
        deleted, freed = prune_run(r, dry_run=args.dry_run)
        actually_pruned += 1
        files_deleted_total += deleted
        bytes_freed_total += freed
        if not args.quiet:
            verb = "WOULD prune" if args.dry_run else "pruned"
            print(f"  {verb} {r.relative_path}  ({fmt_bytes(freed)})")

    print(file=sys.stderr)
    print(f"Anchor (now):              {anchor.isoformat()}", file=sys.stderr)
    print(f"Runs discovered:           {len(runs)}", file=sys.stderr)
    print(f"  Pinned (always kept):    {stats['pinned']}", file=sys.stderr)
    print(f"  No timestamp (kept):     {stats['skipped_no_timestamp']}", file=sys.stderr)
    print(file=sys.stderr)
    print(f"Retained by tier:", file=sys.stderr)
    print(f"  Tier 0 (0-30d, all):           {stats['tier_0_keep_all']:>6}", file=sys.stderr)
    print(f"  Tier 1 (30-60d, half):         {stats['tier_1_half']:>6}", file=sys.stderr)
    print(f"  Tier 2 (60-90d, last/day):     {stats['tier_2_last_of_day']:>6}", file=sys.stderr)
    print(f"  Tier 3 (90d-1y, Sun+Wed):      {stats['tier_3_sun_wed']:>6}", file=sys.stderr)
    print(f"  Tier 4 (1y+, last/month):      {stats['tier_4_last_of_month']:>6}", file=sys.stderr)
    print(file=sys.stderr)
    mode_label = "DRY RUN" if args.dry_run else "APPLIED"
    print(f"[{mode_label}]", file=sys.stderr)
    print(f"  Already pruned (skipped):  {already_pruned}", file=sys.stderr)
    print(f"  Pruned this pass:          {actually_pruned}", file=sys.stderr)
    print(f"  Files deleted:             {files_deleted_total}", file=sys.stderr)
    print(f"  Bytes freed:               {fmt_bytes(bytes_freed_total)}", file=sys.stderr)


if __name__ == "__main__":
    main()
