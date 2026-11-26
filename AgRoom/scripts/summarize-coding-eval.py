#!/usr/bin/env python3
"""Aggregate versioned coding-evaluation JSON without treating missing usage as zero."""
import argparse
import hashlib
import json
import statistics
from pathlib import Path


def summarize(reports):
    groups = {}
    for report in reports:
        required = ("task", "taskVersion", "fixtureDigest", "variant", "model", "providerID", "parameters",
                    "maxTaskTokens", "maxToolCalls", "deadlineSeconds", "toolNames", "phase", "passed")
        if not all(key in report for key in required):
            continue  # Legacy/ad-hoc reports cannot silently join the versioned benchmark.
        identity = {key: report[key] for key in required if key not in ("passed",)}
        key = json.dumps(identity, sort_keys=True, ensure_ascii=False)
        groups.setdefault(key, []).append(report)
    result = []
    for key, runs in sorted(groups.items()):
        identity = json.loads(key)
        count = len(runs)
        passed = sum(run["passed"] is True for run in runs)
        complete_usage = all(run.get("missingUsageRequests", 1) == 0
                             and run.get("requests", 0) > 0 for run in runs)
        reported_tokens = sum(run.get("reportedInputTokens", 0) + run.get("reportedOutputTokens", 0) for run in runs)
        timings = sorted(run["totalSeconds"] for run in runs if isinstance(run.get("totalSeconds"), (int, float)))
        result.append({
            "configuration": identity,
            "configurationDigest": hashlib.sha256(key.encode()).hexdigest(),
            "runs": count, "passed": passed, "passRate": passed / count,
            "falseCompletions": sum(run.get("falseCompletion") is True for run in runs),
            "reportedTokensIncludingFailures": reported_tokens,
            "usageComplete": complete_usage,
            "tokensPerSuccessfulTaskIncludingFailures": reported_tokens / passed if complete_usage and passed else None,
            "reportedCacheReadTokens": sum(run.get("reportedCacheReadTokens", 0) for run in runs),
            "reportedCacheWriteTokens": sum(run.get("reportedCacheWriteTokens", 0) for run in runs),
            "missingCacheReadRequests": sum(run.get("missingCacheReadRequests", run.get("requests", 0)) for run in runs),
            "missingCacheWriteRequests": sum(run.get("missingCacheWriteRequests", run.get("requests", 0)) for run in runs),
            "failedRequests": sum(run.get("failedRequests", 0) for run in runs),
            "failedToolCalls": sum(run.get("failedToolCalls", 0) for run in runs),
            "scriptedApprovals": sum(run.get("scriptedApprovals", 0) for run in runs),
            "humanInterventions": sum(run.get("humanInterventions", 0) for run in runs),
            "medianTotalSeconds": statistics.median(timings) if timings else None,
            "cost": None,  # Token counts do not establish the provider's bill or write-cache price.
        })
    return {"schemaVersion": 1, "groups": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    reports = []
    for path in sorted(args.directory.glob("*.json")):
        value = json.loads(path.read_text())
        if isinstance(value, dict):
            reports.append(value)
    print(json.dumps(summarize(reports), ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
