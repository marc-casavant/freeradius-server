#!/usr/bin/env python3
"""
parse_results.py — parse callgrind profiling results into a sharded set of
JSON files suitable for fetch-on-demand consumption by the dashboard.

Run this script manually after new profiling results have been added to
prof-results (either via CI or a local profiling run):

    In CI (after the profiling-tests job):
        python3 scripts/profiling/parse_results.py --results-dir prof-results

    Locally (from the repo root):
        python3 scripts/profiling/parse_results.py --results-dir prof-results

Usage:
    python3 parse_results.py [--results-dir <path>] [--output-dir <path>]
                             [--top-n <int>] [--window-days <int>]
                             [--window-runs <int>]
                             [--mad-floor <float>] [--min-delta-pp <float>]
                             [--delta-info-pp <float>] [--delta-warn-pp <float>]
                             [--delta-crit-pp <float>] [--delta-improve-pp <float>]

Expected raw results layout under <results-dir>:

    <branch>/<sha>/<run>/<suite>/<test>/
        callgrind_report.txt
        valgrind_profiling.log

Layout produced under <output-dir> (default: same as <results-dir>):

    index.json                                          # global summary, one record per run
    <branch>/<sha>/<run>/<suite>/<test>/
        summary.json                                    # totals + top 25 fns + flags
        full.json                                       # all functions, full per-fn rolling stats
    baselines/<suite>/<branch>.json                     # window aggregate per scope

The dashboard fetches index.json on load, then summary.json for each run in
the user's selected window, and full.json only when the user drills into a
specific run.

Severity classification is based on ABSOLUTE delta in percentage points
(not z-score), since valgrind runs on a fixed host are deterministic and
historical MAD reflects mainly profiler precision rather than real jitter.
The robust z-score is still computed (with a configurable MAD floor) and
stored alongside the absolute delta for use as a secondary sort key.

All thresholds are exposed via CLI flags so they can be tuned without
editing the script.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from pathlib import Path


# ---------------------------------------------------------------------------
# Module classification
# ---------------------------------------------------------------------------

def derive_module(library: str, file_path: str) -> str:
    """Map a library path to a short human-readable module name."""
    if library == "???" or not library:
        return "unknown"
    lib = library.split("/")[-1]
    if "libtalloc" in lib:
        return "talloc"
    if "libc.so" in lib or "libpthread" in lib:
        return "libc"
    if "libkqueue" in lib:
        return "libkqueue"
    if "libfreeradius-util" in lib:
        return "libfreeradius-util"
    if "libfreeradius-server" in lib:
        return "libfreeradius-server"
    if "libfreeradius-ldap" in lib:
        return "rlm_ldap"
    if "libfreeradius-" in lib:
        return lib.split(".")[0].removeprefix("lib")
    if "radiusd" in lib:
        return "radiusd"
    if "rlm_" in lib:
        return lib.split(".")[0]
    return lib.split(".")[0]


# ---------------------------------------------------------------------------
# Parsers — log + callgrind report
# ---------------------------------------------------------------------------

def parse_valgrind_log(path: Path, stats_path: Path | None = None) -> dict:
    """Extract high-level metrics from valgrind log files.

    path: valgrind_profiling.log — source of PID and timestamp.
    stats_path: valgrind.log — source of ==PID== stats lines. Falls back to
                path if not given (legacy single-file layout).
    """
    result = {
        "instructions": None,
        "i1_miss_rate": None,
        "ll_miss_rate": None,
        "mispred_rate": None,
        "indirect_mispred_rate": None,
        "timestamp": None,
    }
    try:
        text = path.read_text(errors="replace")
    except FileNotFoundError:
        return result

    m_pid = re.search(r"Freeradius PID:\s*(\d+)", text)
    pid = m_pid.group(1) if m_pid else r"\d+"
    tag = f"=={pid}=="

    m = re.search(r"Profiling complete at (.+)", text)
    if m:
        result["timestamp"] = m.group(1).strip()

    # Stats lines live in valgrind.log (separate from wrapper script output).
    stats_text = text
    if stats_path is not None:
        try:
            stats_text = stats_path.read_text(errors="replace")
        except FileNotFoundError:
            pass

    m = re.search(rf"{re.escape(tag)} I   refs:\s+([\d,]+)", stats_text)
    if m:
        result["instructions"] = int(m.group(1).replace(",", ""))

    m = re.search(rf"{re.escape(tag)} I1  miss rate:\s+([\d.]+)%", stats_text)
    if m:
        result["i1_miss_rate"] = float(m.group(1))

    m = re.search(rf"{re.escape(tag)} LLi miss rate:\s+([\d.]+)%", stats_text)
    if m:
        result["ll_miss_rate"] = float(m.group(1))

    m = re.search(
        rf"{re.escape(tag)} Mispred rate:\s+([\d.]+)%\s+\(\s*([\d.]+)%.*?\+\s*([\d.]+)%",
        stats_text,
    )
    if m:
        result["mispred_rate"] = float(m.group(1))
        result["indirect_mispred_rate"] = float(m.group(3))

    return result


def parse_callgrind_report(path: Path, top_n: int | None = None) -> tuple[int | None, list[dict]]:
    """
    Parse the flat function table out of a callgrind_annotate report.
    Returns (total_ir, [function_records]).

    If top_n is None, all functions in the table are kept.
    """
    total_ir: int | None = None
    functions: list[dict] = []
    in_fn_table = False

    try:
        lines = path.read_text(errors="replace").splitlines()
    except FileNotFoundError:
        return total_ir, functions

    for line in lines:
        if "PROGRAM TOTALS" in line:
            m = re.match(r"\s*([\d,]+)\s+\(100\.0%\)", line)
            if m:
                total_ir = int(m.group(1).replace(",", ""))
            in_fn_table = False
            continue

        if re.search(r"\bfile:function\b", line):
            in_fn_table = True
            continue

        if not in_fn_table:
            continue

        if line.startswith("---") or line.startswith(" --"):
            if functions:
                break
            continue

        line = line.rstrip()
        if not line.strip():
            continue

        m_id = re.search(r'(\S+):(\S+)\s+\[([^\]]+)\]\s*$', line)
        if not m_id:
            continue

        file_path_str = m_id.group(1)
        func_name = m_id.group(2)
        library = m_id.group(3)

        if func_name.startswith("0x"):
            continue

        m_pct = re.match(r"\s*([\d,]+)\s+\(\s*([\d.]+)%\)", line)
        if not m_pct:
            continue

        ir_pct = float(m_pct.group(2))
        module = derive_module(library, file_path_str)

        functions.append({
            "name": func_name,
            "module": module,
            "library": library,
            "file": file_path_str,
            "self_ir_pct": ir_pct,
        })

        if top_n is not None and len(functions) >= top_n:
            break

    return total_ir, functions


# ---------------------------------------------------------------------------
# Run model + walker
# ---------------------------------------------------------------------------

@dataclass
class Run:
    test_suite: str
    test_name: str
    branch: str
    sha: str
    run_number: int
    timestamp_iso: str | None        # ISO 8601, UTC, parsed from log
    timestamp_raw: str | None        # original "Wed May  6 14:58:35 UTC 2026" text
    instructions: int | None
    i1_miss_rate: float | None
    ll_miss_rate: float | None
    mispred_rate: float | None
    indirect_mispred_rate: float | None
    total_ir_annotated: int | None
    top_functions: list[dict] = field(default_factory=list)

    @property
    def key_tuple(self) -> tuple[str, str, int, str, str]:
        # ordered to match the on-disk tree: branch / sha / run_number / suite / test
        return (self.branch, self.sha, self.run_number, self.test_suite, self.test_name)

    @property
    def baseline_scope(self) -> str:
        # rolling baselines are scoped per test_suite × branch
        return f"{self.test_suite}::{self.branch}"

    @property
    def relative_path(self) -> str:
        # path relative to <results-dir>; summary.json/full.json are written here alongside the raw data
        return f"{self.branch}/{self.sha}/{self.run_number}/{self.test_suite}/{self.test_name}"


def parse_log_timestamp(raw: str | None) -> str | None:
    """
    Convert "Wed May  6 14:58:35 UTC 2026" (the format used in the log) to
    a canonical ISO 8601 UTC string. Returns None if parsing fails.
    """
    if not raw:
        return None
    fmts = [
        "%a %b %d %H:%M:%S %Z %Y",
        "%a %b  %d %H:%M:%S %Z %Y",
    ]
    for fmt in fmts:
        try:
            dt = datetime.strptime(raw.strip(), fmt)
            return dt.replace(tzinfo=timezone.utc).isoformat()
        except ValueError:
            continue
    return None


_SKIP_TOP_LEVEL = frozenset({"baselines", "runs", "index.html", ".git", ".DS_Store"})


def walk_results(results_dir: Path, top_n: int | None) -> list[Run]:
    """Walk the prof-results tree and parse each leaf into a Run record.

    Expected tree layout:
        <results-dir>/<branch>/<sha>/<run-number>/<test-suite>/<test-name>/
            callgrind_report.txt
            valgrind_profiling.log
    """
    runs: list[Run] = []

    if not results_dir.is_dir():
        print(f"ERROR: results directory not found: {results_dir}", file=sys.stderr)
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

                for test_suite_dir in sorted(run_dir.iterdir()):
                    if not test_suite_dir.is_dir():
                        continue
                    test_suite = test_suite_dir.name

                    for test_name_dir in sorted(test_suite_dir.iterdir()):
                        if not test_name_dir.is_dir():
                            continue
                        test_name = test_name_dir.name
                        leaf = test_name_dir

                        # Skip leaves the pruner has deliberately emptied of raw
                        if (leaf / ".pruned").exists():
                            continue

                        vlog   = leaf / "valgrind_profiling.log"
                        report = leaf / "callgrind_report.txt"

                        metrics = parse_valgrind_log(vlog, leaf / "valgrind.log")
                        total_ir, top_fns = parse_callgrind_report(report, top_n)

                        if not metrics["instructions"]:
                            print(
                                f"  SKIP {branch}/{sha}/{run_number}/{test_suite}/{test_name}"
                                " — no instruction count found",
                                file=sys.stderr,
                            )
                            continue

                        runs.append(Run(
                            test_suite=test_suite,
                            test_name=test_name,
                            branch=branch,
                            sha=sha,
                            run_number=run_number,
                            timestamp_iso=parse_log_timestamp(metrics["timestamp"]),
                            timestamp_raw=metrics["timestamp"],
                            instructions=metrics["instructions"],
                            i1_miss_rate=metrics["i1_miss_rate"],
                            ll_miss_rate=metrics["ll_miss_rate"],
                            mispred_rate=metrics["mispred_rate"],
                            indirect_mispred_rate=metrics["indirect_mispred_rate"],
                            total_ir_annotated=total_ir,
                            top_functions=top_fns,
                        ))

    return runs


# ---------------------------------------------------------------------------
# Rolling baselines
#
# We distinguish three different things, because lumping them together makes
# the per-run JSON files unnecessarily fat:
#
#   1. Per-run REGRESSION FLAGS — a short list of functions that deviated
#      significantly from their own rolling history. Severity is driven by
#      the ABSOLUTE delta (not z-score), with all thresholds CLI-tunable.
#      Shipped in summary.json. Cost: a few hundred bytes per run.
#
#   2. Per-run ROLLING STATS — the full per-function median/MAD/min/max
#      computed against the runs that came before this one in the same
#      scope. This is what the function drill-down view needs to draw the
#      history band. Shipped in full.json (which is fetched on demand only).
#
#   3. Window AGGREGATE — a single per-scope (test_suite × branch) record
#      summarising "best / worst / median / MAD" for each function across
#      the most recent N runs. Shipped in baselines/<suite>/<branch>.json
#      and fetched once when the dashboard shows runs in that scope.
#      This is what powers the "best/worst over recent window" markers.
#
# Splitting them this way keeps summary.json (preloaded for ~200 runs) light
# while still giving every consumer the data it needs.
# ---------------------------------------------------------------------------


def median_abs_dev(values: list[float], med: float) -> float:
    if not values:
        return 0.0
    return statistics.median(abs(v - med) for v in values)


def robust_z(current: float, med: float, mad: float, mad_floor: float) -> float:
    """
    Robust z-score with a MAD floor. The floor prevents the score from
    blowing up when the historical window is tightly clustered (which is
    common when CI is deterministic on a fixed host). The effective floor
    is the larger of an absolute precision floor and 1% of the median.

    Z-score is computed for prioritization/display; severity is based
    on absolute delta_pp, not z, since absolute change is the actionable
    quantity in deterministic environments.
    """
    effective_floor = max(mad_floor, med * 0.01)
    mad = max(mad, effective_floor)
    if mad == 0:
        return 0.0
    return (current - med) / (1.4826 * mad)


def _per_fn_stats(window_runs: list[Run]) -> dict[str, dict]:
    """Aggregate self_ir_pct values across a window into per-function stats."""
    per_fn: dict[str, list[float]] = defaultdict(list)
    for h in window_runs:
        for fn in h.top_functions:
            per_fn[fn["name"]].append(fn["self_ir_pct"])

    stats: dict[str, dict] = {}
    for name, values in per_fn.items():
        if not values:
            continue
        med = statistics.median(values)
        stats[name] = {
            "n": len(values),
            "median": round(med, 4),
            "mad": round(median_abs_dev(values, med), 4),
            "min": round(min(values), 4),
            "max": round(max(values), 4),
        }
    return stats


def _scope_history(run: Run, history: list[Run]) -> list[Run]:
    """Strictly-earlier runs in the same (test_suite, branch) scope."""
    return [
        h for h in history
        if h.baseline_scope == run.baseline_scope
        and h.key_tuple < run.key_tuple
    ]


def _window_by_date(history: list[Run], anchor_iso: str | None, days: int) -> list[Run]:
    if not anchor_iso:
        return []
    try:
        anchor = datetime.fromisoformat(anchor_iso)
    except ValueError:
        return []
    cutoff = anchor - timedelta(days=days)
    out: list[Run] = []
    for h in history:
        if not h.timestamp_iso:
            continue
        try:
            ts = datetime.fromisoformat(h.timestamp_iso)
        except ValueError:
            continue
        if ts >= cutoff:
            out.append(h)
    return out


def compute_per_run_flags(
    run: Run,
    history: list[Run],
    *,
    window_days: int,
    window_runs: int,
    mad_floor: float = 0.02,
    min_delta_pp: float = 0.10,
    delta_info_pp: float = 0.10,
    delta_warn_pp: float = 0.30,
    delta_crit_pp: float = 1.00,
    delta_improve_pp: float = 0.30,
) -> dict:
    """
    Detect regressions and improvements for THIS run by comparing each of
    its functions' self_ir_pct against the rolling median over the count-
    based window in the same scope.

    Severity is determined by ABSOLUTE delta in percentage points, not by
    z-score. This is appropriate for an environment where valgrind runs
    are deterministic on fixed hosts and historical MAD reflects mainly
    profiler precision (≈0.01 pp), not real run-to-run jitter. A z-score
    against that tiny MAD would treat any change as catastrophic.

    Z-score is still computed (with a MAD floor) and stored so the
    dashboard can use it as a secondary sort key, but it does not drive
    severity classification.

    The count-based window handles gaps in CI cadence better than a date
    window — if no runs occurred for several days then suddenly many
    happen, a 7-day window has no history to flag against.
    """
    same_scope = _scope_history(run, history)
    same_scope.sort(key=lambda r: ((r.timestamp_iso or ""), r.key_tuple))

    by_count = same_scope[-window_runs:]
    stats = _per_fn_stats(by_count)

    flags: list[dict] = []
    for fn in run.top_functions:
        s = stats.get(fn["name"])
        if not s or s["n"] < 5:
            # Not enough history yet
            continue

        delta = fn["self_ir_pct"] - s["median"]

        # Magnitude floor — below this we treat it as profiler precision noise
        if abs(delta) < min_delta_pp:
            continue

        # Severity by absolute delta
        if delta >= delta_crit_pp:
            severity = "critical"
        elif delta >= delta_warn_pp:
            severity = "warning"
        elif delta >= delta_info_pp:
            severity = "info"
        elif delta <= -delta_improve_pp:
            severity = "improvement"
        else:
            # Negative-but-small deltas (e.g. between -0.10 and -0.30) we
            # treat as noise rather than improvements. Adjust the
            # improvement threshold downward if you want to surface them.
            continue

        z = robust_z(fn["self_ir_pct"], s["median"], s["mad"], mad_floor)

        flags.append({
            "name": fn["name"],
            "module": fn["module"],
            "self_ir_pct": fn["self_ir_pct"],
            "median": s["median"],
            "mad": s["mad"],
            "delta_pp": round(delta, 4),
            "z_robust": round(z, 3),
            "severity": severity,
        })

    # Sort by absolute delta (primary); z-score is informational only
    flags.sort(key=lambda f: abs(f["delta_pp"]), reverse=True)

    return {
        "scope": run.baseline_scope,
        "window_runs": window_runs,
        "window_n": len(by_count),
        "min_delta_pp": min_delta_pp,
        "mad_floor": mad_floor,
        "thresholds": {
            "info_pp": delta_info_pp,
            "warning_pp": delta_warn_pp,
            "critical_pp": delta_crit_pp,
            "improvement_pp": delta_improve_pp,
        },
        "flagged": flags,
    }


def compute_per_run_full_baselines(
    run: Run,
    history: list[Run],
    *,
    window_days: int,
    window_runs: int,
) -> dict:
    """
    Full per-function rolling stats for THIS run, both date- and count-
    based. Goes in full.json. Used by the function drill-down view to
    render the history band.
    """
    same_scope = _scope_history(run, history)
    same_scope.sort(key=lambda r: ((r.timestamp_iso or ""), r.key_tuple))

    by_count = same_scope[-window_runs:]
    by_date = _window_by_date(same_scope, run.timestamp_iso, window_days)

    return {
        "scope": run.baseline_scope,
        "window_days": window_days,
        "window_runs": window_runs,
        "by_date": {
            "n_runs": len(by_date),
            "first_iso": by_date[0].timestamp_iso if by_date else None,
            "last_iso": by_date[-1].timestamp_iso if by_date else None,
            "per_function": _per_fn_stats(by_date),
        },
        "by_count": {
            "n_runs": len(by_count),
            "first_iso": by_count[0].timestamp_iso if by_count else None,
            "last_iso": by_count[-1].timestamp_iso if by_count else None,
            "per_function": _per_fn_stats(by_count),
        },
    }


def compute_scope_aggregates(
    runs_in_scope: list[Run],
    *,
    window_days: int,
    window_runs: int,
) -> dict:
    """
    One aggregate per (test_suite × branch), computed over the most
    recent slice of runs in that scope. This is what the dashboard
    fetches to render best/worst/median markers.
    """
    runs_in_scope = sorted(
        runs_in_scope,
        key=lambda r: ((r.timestamp_iso or ""), r.key_tuple),
    )

    if not runs_in_scope:
        return {}

    last_iso = runs_in_scope[-1].timestamp_iso

    by_count = runs_in_scope[-window_runs:]
    by_date = _window_by_date(runs_in_scope, last_iso, window_days)

    def overview(window: list[Run]) -> dict:
        if not window:
            return {"n_runs": 0}
        instr = [r.instructions for r in window if r.instructions is not None]
        sorted_runs = sorted(window, key=lambda r: r.instructions or 0)
        return {
            "n_runs": len(window),
            "first_iso": window[0].timestamp_iso,
            "last_iso": window[-1].timestamp_iso,
            "instructions": {
                "min": min(instr) if instr else None,
                "max": max(instr) if instr else None,
                "median": int(statistics.median(instr)) if instr else None,
            },
            "best_run": {
                "sha": sorted_runs[0].sha,
                "run_number": sorted_runs[0].run_number,
                "instructions": sorted_runs[0].instructions,
                "path": sorted_runs[0].relative_path,
            } if sorted_runs else None,
            "worst_run": {
                "sha": sorted_runs[-1].sha,
                "run_number": sorted_runs[-1].run_number,
                "instructions": sorted_runs[-1].instructions,
                "path": sorted_runs[-1].relative_path,
            } if sorted_runs else None,
            "per_function": _per_fn_stats(window),
        }

    return {
        "scope": runs_in_scope[0].baseline_scope,
        "window_days": window_days,
        "window_runs": window_runs,
        "by_date": overview(by_date),
        "by_count": overview(by_count),
    }


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def make_summary_record(run: Run, flags: dict, top_n_summary: int = 25) -> dict:
    """The skinny per-run record. Top-N functions plus regression flags."""
    return {
        "test_suite": run.test_suite,
        "test_name": run.test_name,
        "branch": run.branch,
        "sha": run.sha,
        "run_number": run.run_number,
        "timestamp_iso": run.timestamp_iso,
        "timestamp_raw": run.timestamp_raw,
        "totals": {
            "instructions": run.instructions,
            "i1_miss_rate": run.i1_miss_rate,
            "ll_miss_rate": run.ll_miss_rate,
            "mispred_rate": run.mispred_rate,
            "indirect_mispred_rate": run.indirect_mispred_rate,
            "total_ir_annotated": run.total_ir_annotated,
        },
        "top_functions": run.top_functions[:top_n_summary],
        "flags": flags,        # per-run regression flags only — light
    }


def make_full_record(run: Run, full_baselines: dict, flags: dict) -> dict:
    """The fat per-run record. All functions + full per-function rolling stats."""
    return {
        "test_suite": run.test_suite,
        "test_name": run.test_name,
        "branch": run.branch,
        "sha": run.sha,
        "run_number": run.run_number,
        "timestamp_iso": run.timestamp_iso,
        "timestamp_raw": run.timestamp_raw,
        "totals": {
            "instructions": run.instructions,
            "i1_miss_rate": run.i1_miss_rate,
            "ll_miss_rate": run.ll_miss_rate,
            "mispred_rate": run.mispred_rate,
            "indirect_mispred_rate": run.indirect_mispred_rate,
            "total_ir_annotated": run.total_ir_annotated,
        },
        "top_functions": run.top_functions,        # full list
        "rolling_baselines": full_baselines,
        "flags": flags,
    }


def make_index_record(run: Run, flag_count: int) -> dict:
    """Tiny record for the global index."""
    top_module = run.top_functions[0]["module"] if run.top_functions else None
    return {
        "test_suite": run.test_suite,
        "test_name": run.test_name,
        "branch": run.branch,
        "sha": run.sha,
        "run_number": run.run_number,
        "timestamp_iso": run.timestamp_iso,
        "instructions": run.instructions,
        "indirect_mispred_rate": run.indirect_mispred_rate,
        "top_module": top_module,
        "n_flagged": flag_count,
        "path": run.relative_path,
    }


def write_json(path: Path, payload: dict) -> int:
    """Write JSON compactly (no indent — dashboard reads, not humans).
    Returns bytes written.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, separators=(",", ":"), default=str)
    path.write_text(text)
    return len(text.encode("utf-8"))


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    here = Path(__file__).resolve().parent
    repo_root = here.parent.parent
    default_results = repo_root / "prof-results"

    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--results-dir", type=Path, default=default_results,
        help=f"Path to prof-results directory (default: {default_results})",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=None,
        help="Where to write index.json and runs/. Defaults to --results-dir.",
    )
    parser.add_argument(
        "--top-n", type=int, default=None,
        help="Cap functions per run (default: keep all from the report).",
    )
    parser.add_argument(
        "--top-n-summary", type=int, default=25,
        help="How many top functions to keep in summary.json (default: 25).",
    )
    parser.add_argument(
        "--window-days", type=int, default=7,
        help="Default rolling baseline window in days (default: 7).",
    )
    parser.add_argument(
        "--window-runs", type=int, default=200,
        help="Default rolling baseline window in run-count (default: 200).",
    )
    parser.add_argument(
        "--mad-floor", type=float, default=0.02,
        help="Minimum MAD value (in pp) for the robust z-score, to prevent "
             "blow-up when CI is deterministic. Default: 0.02 pp.",
    )
    parser.add_argument(
        "--min-delta-pp", type=float, default=0.10,
        help="Functions whose absolute change vs. the rolling median is "
             "smaller than this are not flagged. Default: 0.10 pp.",
    )
    parser.add_argument(
        "--delta-info-pp", type=float, default=0.10,
        help="Threshold for 'info' severity (regression). Default: 0.10 pp.",
    )
    parser.add_argument(
        "--delta-warn-pp", type=float, default=0.30,
        help="Threshold for 'warning' severity (regression). Default: 0.30 pp.",
    )
    parser.add_argument(
        "--delta-crit-pp", type=float, default=1.00,
        help="Threshold for 'critical' severity (regression). Default: 1.00 pp.",
    )
    parser.add_argument(
        "--delta-improve-pp", type=float, default=0.30,
        help="Threshold for 'improvement' severity (an absolute drop of at "
             "least this many pp). Default: 0.30 pp.",
    )
    parser.add_argument(
        "--quiet", action="store_true",
        help="Suppress per-file progress output.",
    )
    args = parser.parse_args()

    output_dir = args.output_dir or args.results_dir

    # 1. Walk and parse
    runs = walk_results(args.results_dir, top_n=args.top_n)
    print(f"Parsed {len(runs)} run(s) from {args.results_dir}", file=sys.stderr)

    if not runs:
        sys.exit(0)

    # Sort runs canonically before computing baselines
    runs.sort(key=lambda r: ((r.timestamp_iso or ""), r.key_tuple))

    # 2. Per-run output: summary.json + full.json
    total_summary_bytes = 0
    total_full_bytes = 0
    flag_counts: list[int] = []

    for i, run in enumerate(runs):
        history = runs[:i]

        flags = compute_per_run_flags(
            run, history,
            window_days=args.window_days,
            window_runs=args.window_runs,
            mad_floor=args.mad_floor,
            min_delta_pp=args.min_delta_pp,
            delta_info_pp=args.delta_info_pp,
            delta_warn_pp=args.delta_warn_pp,
            delta_crit_pp=args.delta_crit_pp,
            delta_improve_pp=args.delta_improve_pp,
        )
        full_bl = compute_per_run_full_baselines(
            run, history,
            window_days=args.window_days,
            window_runs=args.window_runs,
        )

        flag_counts.append(len(flags["flagged"]))

        summary_path = output_dir / run.relative_path / "summary.json"
        full_path    = output_dir / run.relative_path / "full.json"

        total_summary_bytes += write_json(
            summary_path,
            make_summary_record(run, flags, args.top_n_summary),
        )
        total_full_bytes += write_json(
            full_path,
            make_full_record(run, full_bl, flags),
        )

        if not args.quiet:
            print(
                f"  [{i + 1}/{len(runs)}] {run.relative_path}  "
                f"({len(run.top_functions)} fns, "
                f"window n={flags['window_n']}, "
                f"flagged={len(flags['flagged'])})",
                file=sys.stderr,
            )

    # 3. Per-scope baselines: one file per (test_suite × branch)
    by_scope: dict[str, list[Run]] = defaultdict(list)
    for r in runs:
        by_scope[r.baseline_scope].append(r)

    total_scope_bytes = 0
    for scope, scope_runs in by_scope.items():
        agg = compute_scope_aggregates(
            scope_runs,
            window_days=args.window_days,
            window_runs=args.window_runs,
        )
        # Path: baselines/<test_suite>/<branch>.json
        # We split scope on "::" since that's how baseline_scope is built
        ts, br = scope.split("::", 1)
        scope_path = output_dir / "baselines" / ts / f"{br}.json"
        total_scope_bytes += write_json(scope_path, agg)

    # 4. Global index
    index = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "n_runs": len(runs),
        "window_defaults": {
            "days": args.window_days,
            "runs": args.window_runs,
        },
        "scopes": sorted(by_scope.keys()),
        "runs": [
            make_index_record(r, flag_counts[i])
            for i, r in enumerate(runs)
        ],
    }
    index_path = output_dir / "index.json"
    index_bytes = write_json(index_path, index)

    print(file=sys.stderr)
    print(f"  index.json:                {index_bytes:>10,} bytes  ->  {index_path}", file=sys.stderr)
    print(f"  summary.json (per-run):    {total_summary_bytes:>10,} bytes  ({total_summary_bytes // max(len(runs),1):>5,} avg)", file=sys.stderr)
    print(f"  full.json (per-run):       {total_full_bytes:>10,} bytes  ({total_full_bytes // max(len(runs),1):>5,} avg)", file=sys.stderr)
    print(f"  baselines/ (per-scope):    {total_scope_bytes:>10,} bytes  ({len(by_scope)} scope(s))", file=sys.stderr)
    print(f"  total:                     {index_bytes + total_summary_bytes + total_full_bytes + total_scope_bytes:>10,} bytes", file=sys.stderr)


if __name__ == "__main__":
    main()
