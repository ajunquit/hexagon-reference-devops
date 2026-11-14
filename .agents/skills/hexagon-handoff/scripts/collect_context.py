#!/usr/bin/env python3
"""Collect read-only Git facts and optional GitHub observations for a handoff."""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit


def redact(value):
    if isinstance(value, dict):
        return {key: redact(item) for key, item in value.items()}
    if isinstance(value, list):
        return [redact(item) for item in value]
    if not isinstance(value, str):
        return value
    for name in (
        "GH_TOKEN", "GITHUB_TOKEN", "GITHUB_PACKAGES_TOKEN", "HEXAGON_CORE_READ_TOKEN"
    ):
        secret = os.environ.get(name)
        if secret:
            value = value.replace(secret, "[redacted]")
    return re.sub(
        r"github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+|Bearer\s+\S+",
        "[redacted]", value, flags=re.IGNORECASE,
    )


def run(arguments, directory):
    environment = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")
    try:
        result = subprocess.run(
            arguments, cwd=directory, stdin=subprocess.DEVNULL, capture_output=True,
            timeout=45, env=environment, shell=False,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        # Raw stderr may contain credentials embedded in remote URLs.
        return result.returncode, result.stdout.decode("utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return -1, ""


def git(directory, *arguments):
    return run(["git", "-C", str(directory), *arguments], directory)


def github_name(remote):
    if remote.startswith("git@github.com:"):
        path = remote[len("git@github.com:"):]
    else:
        try:
            parsed = urlsplit(remote)
        except ValueError:
            return None
        if parsed.hostname != "github.com" or parsed.scheme not in ("https", "ssh"):
            return None
        path = parsed.path.lstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    return path if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", path) else None


def status_entries(value):
    entries = value.split("\0")
    changes = []
    index = 0
    while index < len(entries) and entries[index]:
        entry = entries[index]
        if len(entry) < 4 or entry[2] != " ":
            raise ValueError("git.invalidStatus")
        change = {"index": entry[0], "worktree": entry[1], "path": entry[3:]}
        if "R" in entry[:2] or "C" in entry[:2]:
            index += 1
            if index >= len(entries) or not entries[index]:
                raise ValueError("git.invalidRename")
            change["original_path"] = entries[index]
        changes.append(change)
        index += 1
    return changes


def observe_github(root, repository, branch, head):
    if not repository:
        return {"status": "not_configured", "reason": "github.remoteUnavailable"}
    code, body = run([
        "gh", "repo", "view", repository, "--json",
        "nameWithOwner,visibility,defaultBranchRef",
    ], root)
    if code:
        return {"status": "unverifiable", "reason": "github.repositoryUnavailable"}
    try:
        metadata = json.loads(body)
        if (not isinstance(metadata, dict) or
                str(metadata.get("nameWithOwner", "")).casefold() != repository.casefold() or
                metadata.get("visibility") not in ("PRIVATE", "PUBLIC", "INTERNAL")):
            raise ValueError("github.invalidRepository")
        result = {"status": "observed", "repository": {
            key: metadata.get(key) for key in ("nameWithOwner", "visibility", "defaultBranchRef")
        }}
        if not branch:
            result["pull_requests"] = {"status": "not_checked", "reason": "git.detachedHead"}
            return result
        code, body = run([
            "gh", "pr", "list", "--repo", repository, "--state", "all", "--head", branch,
            "--limit", "100", "--json",
            "number,url,state,isDraft,headRefOid,baseRefName,mergedAt,mergeCommit,statusCheckRollup",
        ], root)
        if code:
            result["pull_requests"] = {"status": "unverifiable", "reason": "github.pullRequestsUnavailable"}
            return result
        prs = json.loads(body)
        if not isinstance(prs, list):
            raise ValueError("github.invalidResponse")
        result["pull_requests"] = {
            "status": "observed", "head_branch_filter": branch,
            "possibly_truncated": len(prs) >= 100,
            "items": [{
                **{key: pr.get(key) for key in (
                    "number", "url", "state", "isDraft", "headRefOid", "baseRefName",
                    "mergedAt", "mergeCommit", "statusCheckRollup",
                )}, "head_matches_checkout": pr.get("headRefOid") == head,
            } for pr in prs],
        }
        return result
    except (ValueError, TypeError, KeyError):
        return {"status": "unverifiable", "reason": "github.invalidResponse"}


def collect(path, with_github=False):
    directory = Path(path).resolve()
    code, root_value = git(directory, "rev-parse", "--show-toplevel")
    if code:
        return {"path": str(directory), "status": "unverifiable", "reason": "git.repositoryUnavailable"}
    root = Path(root_value.strip())
    code, head = git(root, "rev-parse", "--verify", "HEAD")
    if code:
        return {"path": str(root), "status": "unverifiable", "reason": "git.headUnavailable"}
    head = head.strip()
    code, branch = git(root, "symbolic-ref", "--short", "-q", "HEAD")
    branch = branch.strip() if code == 0 else None
    code, dirty = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    if code:
        return {"path": str(root), "status": "unverifiable", "reason": "git.statusUnavailable"}
    try:
        changes = status_entries(dirty)
    except ValueError:
        return {"path": str(root), "status": "unverifiable", "reason": "git.invalidStatus"}
    code, remote = git(root, "remote", "get-url", "origin")
    repository = github_name(remote.strip()) if code == 0 else None
    code, upstream = git(root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    return {
        "path": str(root), "status": "observed", "branch": branch, "head": head,
        "upstream": upstream.strip() if code == 0 else None,
        "remote_refs_refreshed": False, "dirty": bool(changes), "changes": changes,
        "github_repository": repository,
        "github": observe_github(root, repository, branch, head) if with_github
            else {"status": "not_checked"},
        "test_results": {"status": "not_collected"},
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", action="append", help="Local repository path; repeat for multiple repositories")
    parser.add_argument("--github", action="store_true", help="Query GitHub through authenticated gh (read only)")
    parser.add_argument("--output", help="New private output file; existing files are never overwritten")
    arguments = parser.parse_args(argv)
    repositories = [collect(path, arguments.github) for path in (arguments.repo or [str(Path.cwd())])]
    record = redact({
        "schema_version": 1,
        "observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "repositories": repositories,
    })
    content = json.dumps(record, ensure_ascii=False, indent=2) + "\n"
    try:
        if arguments.output:
            with Path(arguments.output).open("x", encoding="utf-8", newline="\n") as target:
                target.write(content)
        else:
            sys.stdout.write(content)
    except OSError:
        sys.stderr.write("context.outputUnavailable\n")
        return 2
    return 0 if all(item["status"] == "observed" and
        (not arguments.github or item["github"]["status"] == "observed" and
         item["github"].get("pull_requests", {}).get("status") == "observed") for item in repositories) else 1


if __name__ == "__main__":
    raise SystemExit(main())
