"""Refresh the README badges from a full AWM test run and GitHub Releases."""

import argparse
from base64 import b64encode
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
from xml.sax.saxutils import escape


REPOSITORY = "mihaliak/awm"
DOCS = Path(__file__).resolve().parent
CREATE_BADGE_COMMIT = """
mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) {
    commit { oid signature { isValid wasSignedByGitHub } }
  }
}
"""


def command_json(*command):
    return json.loads(subprocess.check_output(command))


def app_coverage(result_bundle):
    report = command_json("xcrun", "xccov", "view", "--report", "--json", result_bundle)
    app_sources = DOCS.parent / "AWM"
    files = [
        file
        for target in report["targets"]
        if target["name"] == "Another Window Management.app"
        for file in target["files"]
        if Path(file["path"]).resolve().is_relative_to(app_sources)
    ]
    covered = sum(file["coveredLines"] for file in files)
    executable = sum(file["executableLines"] for file in files)
    if executable == 0:
        raise SystemExit("No AWM app coverage found. Run the full AWM scheme with coverage enabled.")
    return covered, executable


def latest_release(repository):
    owner, name = repository.split("/", 1)
    report = command_json(
        "gh", "api", "graphql",
        "-f", "query=query($owner: String!, $name: String!) {"
        " repository(owner: $owner, name: $name) { latestRelease { tagName } } }",
        "-f", f"owner={owner}", "-f", f"name={name}",
    )
    release = report["data"]["repository"]["latestRelease"]
    return release["tagName"] if release else None


def badge(label, value, description, color):
    left = 14 + len(label) * 7
    right = 14 + len(value) * 7
    width = left + right
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="20" role="img" aria-labelledby="title">
  <title id="title">{escape(description)}</title>
  <rect width="{width}" height="20" rx="4" fill="{color}"/>
  <path d="M4 0 H{left} V20 H4 Q0 20 0 16 V4 Q0 0 4 0" fill="#45434d"/>
  <g fill="#fff" font-family="Verdana, sans-serif" font-size="11" text-anchor="middle">
    <text x="{left / 2}" y="14">{escape(label)}</text>
    <text x="{left + right / 2}" y="14">{escape(value)}</text>
  </g>
</svg>
'''


def update_release_badge_link(readme, badge_path):
    links = list(re.finditer(r"\[!\[Latest stable release\]\((?P<path>[^)\r\n]+)\)\]\(", readme))
    if len(links) != 1:
        raise SystemExit(f"Expected one latest release badge in README.md, found {len(links)}.")
    link = links[0]
    if not re.fullmatch(r"docs/(?:latest-release|release-badges/[0-9a-f]{16})\.svg", link["path"]):
        raise SystemExit(f"Unexpected latest release badge path in README.md: {link['path']}")
    start, end = link.span("path")
    return readme[:start] + badge_path + readme[end:]


def refresh_badges(repository, result_bundle=None):
    release = latest_release(repository)
    release_label = release or "none"
    release_badge = badge("latest release", release_label,
                          f"Latest stable release: {release_label}", "#5744c5" if release else "#5a5864").encode("utf-8")
    badge_path = DOCS / "release-badges" / f"{sha256(release_badge).hexdigest()[:16]}.svg"
    readme_path = DOCS.parent / "README.md"
    readme = readme_path.read_bytes().decode("utf-8")
    updated_readme = update_release_badge_link(readme, badge_path.relative_to(DOCS.parent).as_posix())
    if result_bundle:
        covered, executable = app_coverage(result_bundle)
        percentage = f"{covered / executable:.1%}"
        coverage_badge = badge("app coverage", percentage,
                               f"App line coverage: {percentage} ({covered:,}/{executable:,})", "#5744c5")
        (DOCS / "coverage.svg").write_text(coverage_badge, encoding="utf-8")
    latest_path = DOCS / "latest-release.svg"
    latest_path.write_bytes(release_badge)
    badge_path.parent.mkdir(exist_ok=True)
    badge_path.write_bytes(release_badge)
    if updated_readme != readme:
        readme_path.write_bytes(updated_readme.encode("utf-8"))
    return [path.relative_to(DOCS.parent).as_posix() for path in (readme_path, latest_path, badge_path)]


def git(*args):
    return subprocess.check_output(("git", *args), cwd=DOCS.parent)


def create_badge_commit(repository, branch, head, paths):
    additions = [
        {"path": path, "contents": b64encode(git("show", f":{path}")).decode("ascii")}
        for path in paths
    ]
    request = {
        "query": CREATE_BADGE_COMMIT,
        "variables": {"input": {
            "branch": {"repositoryNameWithOwner": repository, "branchName": branch},
            "expectedHeadOid": head,
            "message": {"headline": "chore(docs): refresh release badge"},
            "fileChanges": {"additions": additions},
        }},
    }
    response = subprocess.run(("gh", "api", "graphql", "--input", "-"),
                              input=json.dumps(request).encode(), stdout=subprocess.PIPE, check=False)
    try:
        report = json.loads(response.stdout)
    except json.JSONDecodeError:
        raise SystemExit("GitHub did not return JSON for the release badge commit.") from None
    errors = report.get("errors", [])
    if len(errors) == 1 and errors[0].get("type") == "STALE_DATA":
        return None
    if response.returncode or errors:
        raise SystemExit("GitHub rejected the release badge commit.")
    payload = (report.get("data") or {}).get("createCommitOnBranch") or {}
    commit = payload.get("commit") or {}
    signature = commit.get("signature") or {}
    oid = commit.get("oid", "")
    if not re.fullmatch(r"[0-9a-f]{40}", oid or "") or not (
        signature.get("isValid") is True and signature.get("wasSignedByGitHub") is True
    ):
        raise SystemExit("GitHub did not confirm a valid signature for the release badge commit.")
    return oid


def commit_badges(repository, branch):
    if git("status", "--porcelain", "--untracked-files=all"):
        raise SystemExit("A clean checkout is required to commit release badges.")
    attempts = 3
    for attempt in range(attempts):
        head = git("rev-parse", "HEAD").decode().strip()
        badge_paths = refresh_badges(repository)
        git("add", "--", *badge_paths)
        changed = git("diff", "--cached", "--name-only", "--diff-filter=AM", "-z", "--", *badge_paths)
        paths = changed.decode().split("\0")[:-1]
        if not paths:
            print("Release badges are current.")
            return
        oid = create_badge_commit(repository, branch, head, paths)
        if oid:
            print(f"Published signed release badge commit {oid}.")
            return
        if attempt + 1 == attempts:
            break
        git("restore", "--source=HEAD", "--staged", "--worktree", "--", *paths)
        git("fetch", "--no-tags", "origin", f"refs/heads/{branch}")
        if git("rev-parse", "FETCH_HEAD").decode().strip() == head:
            raise SystemExit("GitHub reported a stale release badge commit but the fetched branch did not move.")
        print("The branch moved. Refreshing badges against its new tip.", flush=True)
        git("checkout", "--detach", "FETCH_HEAD")
    raise SystemExit("The branch kept moving while refreshing release badges. Rerun the workflow.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", nargs="?", help="Xcode test result bundle with coverage enabled")
    parser.add_argument("--repo", default=REPOSITORY, help="GitHub repository in owner/name form")
    parser.add_argument("--commit-to-branch", help="publish changed release badges as a signed GitHub commit")
    args = parser.parse_args()
    if args.commit_to_branch:
        if args.result_bundle:
            parser.error("--commit-to-branch refreshes only release badges")
        commit_badges(args.repo, args.commit_to_branch)
    else:
        refresh_badges(args.repo, args.result_bundle)


if __name__ == "__main__":
    main()
