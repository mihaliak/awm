"""Refresh the README badges from a full AWM test run and GitHub Releases."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
from xml.sax.saxutils import escape


REPOSITORY = "mihaliak/awm"
DOCS = Path(__file__).resolve().parent


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result_bundle", nargs="?", help="Xcode test result bundle with coverage enabled")
    parser.add_argument("--repo", default=REPOSITORY, help="GitHub repository in owner/name form")
    args = parser.parse_args()
    release = latest_release(args.repo)
    release_label = release or "none"
    release_badge = badge("latest release", release_label,
                          f"Latest stable release: {release_label}", "#5744c5" if release else "#5a5864").encode("utf-8")
    badge_path = DOCS / "release-badges" / f"{sha256(release_badge).hexdigest()[:16]}.svg"
    readme_path = DOCS.parent / "README.md"
    readme = readme_path.read_bytes().decode("utf-8")
    updated_readme = update_release_badge_link(readme, badge_path.relative_to(DOCS.parent).as_posix())
    if args.result_bundle:
        covered, executable = app_coverage(args.result_bundle)
        percentage = f"{covered / executable:.1%}"
        coverage_badge = badge("app coverage", percentage,
                               f"App line coverage: {percentage} ({covered:,}/{executable:,})", "#5744c5")
        (DOCS / "coverage.svg").write_text(coverage_badge, encoding="utf-8")
    (DOCS / "latest-release.svg").write_bytes(release_badge)
    badge_path.parent.mkdir(exist_ok=True)
    badge_path.write_bytes(release_badge)
    if updated_readme != readme:
        readme_path.write_bytes(updated_readme.encode("utf-8"))


if __name__ == "__main__":
    main()
