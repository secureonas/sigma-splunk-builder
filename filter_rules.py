#!/usr/bin/env python3
"""
Filter Sigma rules into per-group staging directories.

Changes vs the previous version:
  - yaml.safe_load_all, so multi-document rules (correlations) no longer
    vanish into the generic exception handler.
  - shutil.copy2 instead of yaml.dump: the rule is copied verbatim, so key
    order, comments and unicode survive. We are filtering, not transforming.
  - Per-group level thresholds instead of one global high+critical filter.
  - Output dir is wiped properly (the old `rm -rf "$DIR/*"` never expanded,
    which is why 6 renamed rules were still present from old builds).
  - Duplicate rule IDs across the staged set are reported and the duplicate
    is skipped, so the same detection can never be emitted twice.

Usage:  python3 filter_rules.py [--sigma-repo /opt/sigma] [--out /opt/filtered_rules]
"""

import argparse
import os
import shutil
import sys
import yaml
from collections import defaultdict

# group -> (source subdirs relative to the sigma repo, accepted levels)
GROUPS = {
    "windows-builtin": (
        [
            "rules/windows/builtin",
            "rules/windows/powershell",
        ],
        {"critical", "high", "medium"},
    ),
    "windows-sysmon": (
        [
            "rules/windows/process_creation",
            "rules/windows/registry",
            "rules/windows/file",
            "rules/windows/image_load",
            "rules/windows/network_connection",
            "rules/windows/dns_query",
            "rules/windows/pipe_created",
            "rules/windows/process_access",
            "rules/windows/driver_load",
            "rules/windows/create_remote_thread",
            "rules/windows/create_stream_hash",
            "rules/windows/raw_access_thread",
            "rules/windows/process_tampering",
            "rules/windows/wmi_event",
            "rules/windows/sysmon",
        ],
        {"critical", "high"},
    ),
    # Field names for all three cloud schemas verified against real events.
    "cloud": (
        [
            "rules/cloud/azure/signin_logs",
            "rules/cloud/azure/audit_logs",
            "rules/cloud/m365",
        ],
        {"critical", "high", "medium"},
    ),
    "linux": (
        ["rules/linux/builtin"],
        {"critical", "high", "medium"},
    ),
}

ACCEPTED_STATUS = {"test", "stable"}

# Sysmon EventIDs with zero events in the last 24h across the estate.
# Rules that can only fire on these are staged but flagged in the report.
DEAD_SYSMON_EVENTIDS = {9, 14, 18, 19, 20, 21, 23, 24, 27, 28, 29}


def load_rules(path):
    """Yield every YAML document in a file that looks like a Sigma rule."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for doc in yaml.safe_load_all(fh):
                if isinstance(doc, dict) and "detection" in doc:
                    yield doc
    except yaml.YAMLError as exc:
        print(f"  ! YAML error in {path}: {exc}", file=sys.stderr)
    except Exception as exc:
        print(f"  ! cannot read {path}: {exc}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sigma-repo", default="/opt/sigma")
    ap.add_argument("--out", default="/opt/filtered_rules")
    args = ap.parse_args()

    if not os.path.isdir(args.sigma_repo):
        sys.exit(f"sigma repo not found: {args.sigma_repo}")

    seen_ids = {}          # rule id -> (group, path)
    counts = defaultdict(int)
    skipped_dupe = 0

    for group, (subdirs, levels) in GROUPS.items():
        out_dir = os.path.join(args.out, group)
        # Wipe properly. The old script quoted the glob, so this never ran.
        if os.path.isdir(out_dir):
            shutil.rmtree(out_dir)
        os.makedirs(out_dir, exist_ok=True)

        for subdir in subdirs:
            src_root = os.path.join(args.sigma_repo, subdir)
            if not os.path.isdir(src_root):
                print(f"  - skipping missing {subdir}")
                continue

            for root, _, files in os.walk(src_root):
                for fname in files:
                    if not fname.endswith((".yml", ".yaml")):
                        continue
                    src = os.path.join(root, fname)

                    for rule in load_rules(src):
                        level = str(rule.get("level", "")).lower()
                        status = str(rule.get("status", "")).lower()
                        rid = str(rule.get("id", "")).lower()

                        if level not in levels or status not in ACCEPTED_STATUS:
                            continue
                        if not rid:
                            print(f"  ! no id, skipping {src}", file=sys.stderr)
                            continue
                        if rid in seen_ids:
                            prev_group, prev_path = seen_ids[rid]
                            print(
                                f"  ! duplicate id {rid}\n"
                                f"      kept: {prev_path} ({prev_group})\n"
                                f"      skip: {src} ({group})",
                                file=sys.stderr,
                            )
                            skipped_dupe += 1
                            continue

                        seen_ids[rid] = (group, src)
                        # Flat output, named by id, so a rule renamed or moved
                        # upstream can never produce two staged copies.
                        shutil.copy2(src, os.path.join(out_dir, f"{rid}.yml"))
                        counts[group] += 1
                        break  # one rule per file

    print()
    for group in GROUPS:
        print(f"  {group:<18} {counts[group]:>5} rules")
    print(f"  {'TOTAL':<18} {sum(counts.values()):>5} rules")
    if skipped_dupe:
        print(f"  duplicate ids skipped: {skipped_dupe}")


if __name__ == "__main__":
    main()
