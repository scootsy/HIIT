#!/usr/bin/env python3
"""Build the AltStore-format source (apps.json) from this repository's releases.

SideStore and LiveContainer both read this one file: add its URL as a source
and they list the app, offer new versions, and download each IPA from the
release it was published with.

GitHub releases are the record of truth. A release becomes a version in the
feed when it carries two assets: the IPA, and the `release.json` that
`ipa_info.py` wrote from that exact IPA (version, build, size, SHA-256).
Releases published before the feed existed have no `release.json` and are
left out - their IPAs all report the same version, which no installer could
tell apart. Deleting a release removes it from the feed on the next run.

    python3 scripts/build_source.py --repo owner/name --releases releases.json \
        --existing site/apps.json --fetch --output site/apps.json

Standard library only.
"""

import argparse
import json
import os
import re
import subprocess
import sys

METADATA_ASSET = "release.json"
# Everything in a release body after this marker is installation boilerplate,
# not "what changed".
NOTES_MARKER = "<!-- install -->"

DATE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
HEX_COLOR = re.compile(r"^[0-9A-Fa-f]{6}$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
# The categories AltStore and SideStore know; anything else is shown as "Other".
CATEGORIES = {"developer", "entertainment", "games", "lifestyle", "photo-video", "social", "utilities", "other"}


def version_key(text):
    return tuple(int(n) for n in re.findall(r"\d+", text or ""))


def notes_from_body(body):
    """The "what changed" part of a release body."""
    text = (body or "").split(NOTES_MARKER)[0].strip()
    return text or "Maintenance build."


def _asset(release, predicate):
    for asset in release.get("assets") or []:
        if predicate(asset.get("name") or ""):
            return asset
    return None


def version_entry(metadata, date, notes, download_url):
    """One element of the app's `versions` array."""
    return {
        "version": metadata["version"],
        # SideStore/AltStore read buildVersion; LiveContainer reads buildNumber.
        "buildVersion": metadata["buildVersion"],
        "buildNumber": metadata["buildVersion"],
        "date": date,
        "localizedDescription": notes,
        "downloadURL": download_url,
        "size": metadata["size"],
        "sha256": metadata["sha256"],
        "minOSVersion": metadata["minOSVersion"],
    }


def _usable_metadata(metadata, bundle_identifier):
    """None when the metadata can be trusted, else why not."""
    if not isinstance(metadata, dict):
        return "release.json isn't a JSON object"
    for key in ("version", "buildVersion", "size", "sha256", "minOSVersion", "bundleIdentifier"):
        if key not in metadata:
            return f"release.json has no {key}"
    if metadata["bundleIdentifier"] != bundle_identifier:
        return f"release.json describes {metadata['bundleIdentifier']}, not {bundle_identifier}"
    if not SEMVER.match(str(metadata["version"])):
        return f"version {metadata['version']!r} isn't MAJOR.MINOR.PATCH"
    if not isinstance(metadata["size"], int) or metadata["size"] <= 0:
        return "release.json has no usable size"
    if not SHA256.match(str(metadata["sha256"])):
        return "release.json has no usable sha256"
    return None


def build(config, repo, branch, releases, existing=None, metadata_for=None, pending=None):
    """Return (source document, report lines).

    `metadata_for(release)` returns the parsed release.json for a release, or
    None when it can't be had. `existing` is the feed as last published; its
    entries are reused for releases whose IPA hasn't changed, so a normal run
    downloads only the newest release's metadata. `pending` describes a build
    that isn't released yet (pull-request previews):
    {"metadata", "tag", "date", "notes", "downloadURL"}.
    """
    app_config = config["app"]
    bundle_identifier = app_config["bundleIdentifier"]
    report = []

    cached = {}
    cached_permissions = None
    for app in (existing or {}).get("apps") or []:
        if app.get("bundleIdentifier") != bundle_identifier:
            continue
        cached_permissions = app.get("appPermissions")
        for entry in app.get("versions") or []:
            if entry.get("downloadURL"):
                cached[entry["downloadURL"]] = entry

    entries = []
    newest_metadata = None  # metadata of the entry that ends up first, when freshly read

    if pending:
        problem = _usable_metadata(pending["metadata"], bundle_identifier)
        if problem:
            raise ValueError(f"pending build: {problem}")
        entry = version_entry(pending["metadata"], pending["date"], pending["notes"], pending["downloadURL"])
        entries.append((entry, pending["metadata"]))
        report.append(f"+ {entry['version']} ({entry['buildVersion']})  [this build, not yet released]")

    for release in releases:
        tag = release.get("tag_name") or "?"
        if release.get("draft") or release.get("prerelease"):
            report.append(f"- {tag}: skipped (draft or pre-release)")
            continue
        ipa = _asset(release, lambda name: name.lower().endswith(".ipa"))
        if not ipa:
            report.append(f"- {tag}: skipped (no IPA attached)")
            continue
        date = release.get("published_at") or release.get("created_at") or ""
        if not DATE.match(date):
            report.append(f"- {tag}: skipped (no usable publish date)")
            continue
        url = ipa.get("browser_download_url") or ""
        notes = notes_from_body(release.get("body"))

        reused = cached.get(url)
        if reused and reused.get("size") == ipa.get("size"):
            entry = dict(reused)
            entry["date"] = date
            entry["localizedDescription"] = notes
            entries.append((entry, None))
            report.append(f"+ {entry.get('version')} ({entry.get('buildVersion')})  {tag}")
            continue

        if not _asset(release, lambda name: name == METADATA_ASSET):
            report.append(f"- {tag}: skipped (no {METADATA_ASSET}; published before the feed existed)")
            continue
        metadata = metadata_for(release) if metadata_for else None
        if metadata is None:
            report.append(f"- {tag}: skipped ({METADATA_ASSET} couldn't be read)")
            continue
        problem = _usable_metadata(metadata, bundle_identifier)
        if problem:
            report.append(f"- {tag}: skipped ({problem})")
            continue
        if metadata["size"] != ipa.get("size"):
            # The IPA was swapped after publishing: installers would reject
            # the download for not matching the feed.
            report.append(f"- {tag}: skipped (the IPA is {ipa.get('size')} bytes but {METADATA_ASSET} says {metadata['size']})")
            continue
        entry = version_entry(metadata, date, notes, url)
        entries.append((entry, metadata))
        report.append(f"+ {entry['version']} ({entry['buildVersion']})  {tag}")

    # Newest first - installers treat the first version as the latest.
    entries.sort(key=lambda pair: (pair[0]["date"], version_key(pair[0]["version"])), reverse=True)
    seen = set()
    unique = []
    for entry, metadata in entries:
        identity = (entry["version"], entry["buildVersion"])
        if identity in seen:
            report.append(f"- {entry['version']} ({entry['buildVersion']}): dropped an older duplicate")
            continue
        seen.add(identity)
        unique.append((entry, metadata))
    limit = int(config.get("maxVersions", 20))
    if len(unique) > limit:
        report.append(f"  (keeping the newest {limit} of {len(unique)} versions)")
        unique = unique[:limit]

    raw = f"https://raw.githubusercontent.com/{repo}/{branch}"
    source_config = config["source"]
    document = {
        "name": source_config["name"],
        "identifier": source_config["identifier"],
        "subtitle": source_config["subtitle"],
        "description": source_config["description"],
        "iconURL": f"{raw}/icon.png",
        "website": f"https://github.com/{repo}",
        "tintColor": source_config["tintColor"],
        "sourceURL": f"{raw}/apps.json",
        "featuredApps": [bundle_identifier] if unique else [],
        "apps": [],
        "news": [],
    }
    if not unique:
        report.append("  no installable versions yet - the source is valid but empty")
        return document, report

    versions = [entry for entry, _ in unique]
    latest = versions[0]
    newest_metadata = unique[0][1]
    if newest_metadata is not None:
        permissions = {
            "entitlements": list(newest_metadata.get("entitlements") or []),
            "privacy": dict(newest_metadata.get("privacy") or {}),
        }
    else:
        permissions = cached_permissions or {"entitlements": [], "privacy": {}}

    document["apps"].append({
        "name": app_config["name"],
        "bundleIdentifier": bundle_identifier,
        "developerName": app_config["developerName"],
        "subtitle": app_config["subtitle"],
        "localizedDescription": app_config["localizedDescription"],
        "iconURL": f"{raw}/icon.png",
        "tintColor": app_config["tintColor"],
        "category": app_config["category"],
        "screenshotURLs": [],
        "versions": versions,
        "appPermissions": permissions,
        # Older clients read the latest version from these flat fields.
        "version": latest["version"],
        "versionDate": latest["date"],
        "versionDescription": latest["localizedDescription"],
        "downloadURL": latest["downloadURL"],
        "size": latest["size"],
    })
    return document, report


def validate(document):
    """Problems that would stop SideStore or LiveContainer reading the feed.

    Mirrors what their decoders require: SideStore rejects a whole source for
    a missing required field, a malformed URL, an invalid tint colour, an app
    without versions, or a date it can't parse.
    """
    problems = []

    def need(container, key, kind, where):
        value = container.get(key)
        if not isinstance(value, kind) or (isinstance(value, str) and not value):
            problems.append(f"{where}.{key} is missing or not a {kind.__name__}")
            return None
        return value

    def need_url(container, key, where):
        value = need(container, key, str, where)
        if value is not None and not re.match(r"^https://[^\s]+$", value):
            problems.append(f"{where}.{key} is not an https URL: {value!r}")

    def need_color(container, key, where):
        value = container.get(key)
        if value is not None and not (isinstance(value, str) and HEX_COLOR.match(value)):
            problems.append(f"{where}.{key} must be six hex digits, got {value!r}")

    need(document, "name", str, "source")
    need(document, "identifier", str, "source")
    need_url(document, "iconURL", "source")
    need_url(document, "sourceURL", "source")
    need_color(document, "tintColor", "source")
    apps = need(document, "apps", list, "source") or []
    identifiers = set()
    for app in apps:
        where = f"app {app.get('bundleIdentifier', '?')}"
        for key in ("name", "bundleIdentifier", "developerName", "localizedDescription"):
            need(app, key, str, where)
        need_url(app, "iconURL", where)
        need_color(app, "tintColor", where)
        if app.get("bundleIdentifier") in identifiers:
            problems.append(f"{where} is listed twice")
        identifiers.add(app.get("bundleIdentifier"))
        if app.get("category") not in CATEGORIES:
            problems.append(f"{where}.category {app.get('category')!r} isn't one installers know")
        permissions = app.get("appPermissions")
        if not isinstance(permissions, dict) or not isinstance(permissions.get("entitlements"), list) \
                or not isinstance(permissions.get("privacy"), dict):
            problems.append(f"{where}.appPermissions needs an entitlements list and a privacy object")
        versions = app.get("versions")
        if not isinstance(versions, list) or not versions:
            problems.append(f"{where} has no versions (SideStore rejects the whole source)")
            continue
        previous = None
        seen = set()
        for index, entry in enumerate(versions):
            spot = f"{where} version[{index}]"
            version = need(entry, "version", str, spot)
            if version and not SEMVER.match(version):
                problems.append(f"{spot}.version {version!r} isn't MAJOR.MINOR.PATCH")
            build = need(entry, "buildVersion", str, spot)
            if entry.get("buildNumber") != build:
                problems.append(f"{spot}.buildNumber must repeat buildVersion for LiveContainer")
            date = need(entry, "date", str, spot)
            if date and not DATE.match(date):
                problems.append(f"{spot}.date {date!r} isn't YYYY-MM-DDTHH:MM:SSZ")
            need_url(entry, "downloadURL", spot)
            size = entry.get("size")
            if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
                problems.append(f"{spot}.size must be the IPA's size in bytes")
            if not SHA256.match(str(entry.get("sha256", ""))):
                problems.append(f"{spot}.sha256 must be 64 lowercase hex digits")
            need(entry, "minOSVersion", str, spot)
            identity = (version, build)
            if identity in seen:
                problems.append(f"{spot} repeats {version} ({build})")
            seen.add(identity)
            if previous is not None and date and previous < date:
                problems.append(f"{spot} is newer than the entry before it - versions must be newest first")
            previous = date or previous
        latest = versions[0]
        for flat, nested in (("version", "version"), ("versionDate", "date"),
                             ("downloadURL", "downloadURL"), ("size", "size")):
            if app.get(flat) != latest.get(nested):
                problems.append(f"{where}.{flat} doesn't match the newest version")
    for identifier in document.get("featuredApps") or []:
        if identifier not in identifiers:
            problems.append(f"featuredApps names {identifier}, which isn't in apps")
    return problems


def fetch_with_gh(repo):
    """A metadata_for() that downloads release.json with the GitHub CLI."""
    def metadata_for(release):
        tag = release.get("tag_name")
        result = subprocess.run(
            ["gh", "release", "download", tag, "--repo", repo, "--pattern", METADATA_ASSET, "--output", "-"],
            capture_output=True, check=False)
        if result.returncode != 0:
            print(f"warning: couldn't download {METADATA_ASSET} for {tag}: "
                  f"{result.stderr.decode(errors='replace').strip()}", file=sys.stderr)
            return None
        try:
            return json.loads(result.stdout)
        except ValueError:
            return None
    return metadata_for


def read_from_directory(directory):
    """A metadata_for() that reads <directory>/<tag>.json (used by the tests)."""
    def metadata_for(release):
        path = os.path.join(directory, f"{release.get('tag_name')}.json")
        try:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        except (OSError, ValueError):
            return None
    return metadata_for


def _load_json(path, default=None):
    """Parsed JSON, or `default` when the file is missing or isn't JSON."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--branch", default="altstore", help="branch the feed is published on")
    parser.add_argument("--releases", required=True, help="JSON array from the GitHub releases API")
    parser.add_argument("--config", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "source.config.json"))
    parser.add_argument("--existing", help="the feed as last published, if any")
    parser.add_argument("--metadata-dir", help="read <tag>.json files from here instead of downloading")
    parser.add_argument("--fetch", action="store_true", help="download missing release.json files with gh")
    parser.add_argument("--pending", help="release.json of a build that isn't released yet (previews)")
    parser.add_argument("--pending-tag", default="preview")
    parser.add_argument("--pending-date", default="2000-01-01T00:00:00Z")
    parser.add_argument("--pending-notes", default="Preview build.")
    parser.add_argument("--pending-ipa-name", default="HIIT-unsigned.ipa")
    parser.add_argument("--output", "-o", required=True)
    args = parser.parse_args(argv)

    config = _load_json(args.config)
    if config is None:
        print(f"error: can't read {args.config}", file=sys.stderr)
        return 1
    releases = _load_json(args.releases)
    if not isinstance(releases, list):
        print(f"error: {args.releases} isn't a JSON array of releases", file=sys.stderr)
        return 1
    # `gh api --paginate` concatenates pages; tolerate a list of lists.
    if releases and isinstance(releases[0], list):
        releases = [release for page in releases for release in page]

    metadata_for = None
    if args.metadata_dir:
        metadata_for = read_from_directory(args.metadata_dir)
    elif args.fetch:
        metadata_for = fetch_with_gh(args.repo)

    pending = None
    if args.pending:
        pending = {
            "metadata": _load_json(args.pending),
            "tag": args.pending_tag,
            "date": args.pending_date,
            "notes": args.pending_notes,
            "downloadURL": f"https://github.com/{args.repo}/releases/download/{args.pending_tag}/{args.pending_ipa_name}",
        }

    try:
        document, report = build(config, args.repo, args.branch, releases,
                                 existing=_load_json(args.existing) if args.existing else None,
                                 metadata_for=metadata_for, pending=pending)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print("\n".join(report))
    problems = validate(document)
    if problems:
        print("\nThe feed would not load:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    count = sum(len(app["versions"]) for app in document["apps"])
    print(f"\nWrote {args.output}: {count} version(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
