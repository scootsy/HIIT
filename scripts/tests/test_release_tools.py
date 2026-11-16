"""Tests for the release tooling: ipa_info.py and build_source.py.

    python3 -m unittest discover -s scripts/tests -v

The "installer" helpers at the bottom re-implement, from the SideStore and
LiveContainer sources, the parts of their feed parsing and download
verification that a bad feed would trip - so a feed that passes here is one
those apps accept.
"""

import contextlib
import hashlib
import io
import json
import os
import plistlib
import re
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import build_source  # noqa: E402
import ipa_info  # noqa: E402

REPO = "octo/workout"
BUNDLE = "com.scootsy.HIIT"
ALL_ORIENTATIONS = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]


def make_ipa(path, version="1.0.31", build="57", sdk="iphoneos27.1", extension_version=None,
             orientations=None, payload=b"binary"):
    """Write a minimal but structurally real IPA."""
    info = {
        "CFBundleIdentifier": BUNDLE,
        "CFBundleDisplayName": "HIIT Coach",
        "CFBundleName": "HIIT",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "MinimumOSVersion": "17.0",
        "DTSDKName": sdk,
        "DTXcode": "2710",
        "UISupportedInterfaceOrientations": ALL_ORIENTATIONS if orientations is None else orientations,
        "NSBluetoothAlwaysUsageDescription": "Connects to heart-rate monitors.",
        "NSHealthShareUsageDescription": "Reads your heart rate.",
        "NSSupportsLiveActivities": True,
    }
    extension = {
        "CFBundleIdentifier": BUNDLE + ".HIITWidgets",
        "CFBundleShortVersionString": extension_version or version,
        "CFBundleVersion": build,
        "NSHealthUpdateUsageDescription": "Saves workouts.",
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Payload/HIIT.app/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        archive.writestr("Payload/HIIT.app/HIIT", payload)
        archive.writestr("Payload/HIIT.app/PlugIns/HIITWidgets.appex/Info.plist", plistlib.dumps(extension))
        archive.writestr("Payload/HIIT.app/PlugIns/HIITWidgets.appex/HIITWidgets", b"ext")
        # A nested bundle that must not be mistaken for the app or an extension.
        archive.writestr("Payload/HIIT.app/Frameworks/Thing.framework/Info.plist",
                         plistlib.dumps({"CFBundleIdentifier": "x.thing", "NSCameraUsageDescription": "no"}))
    return path


def release(tag, published, ipa_size=None, metadata=True, body="Faster warm-ups.\n\n<!-- install -->\nHow to install…",
            draft=False, prerelease=False):
    assets = []
    if ipa_size is not None:
        assets.append({
            "name": "HIIT-unsigned.ipa",
            "size": ipa_size,
            "browser_download_url": f"https://github.com/{REPO}/releases/download/{tag}/HIIT-unsigned.ipa",
        })
    if metadata:
        assets.append({
            "name": "release.json",
            "size": 400,
            "browser_download_url": f"https://github.com/{REPO}/releases/download/{tag}/release.json",
        })
    return {"tag_name": tag, "published_at": published, "body": body, "draft": draft,
            "prerelease": prerelease, "assets": assets}


def metadata(version, build, size, sha="ab" * 32):
    return {
        "schema": 1, "bundleIdentifier": BUNDLE, "name": "HIIT Coach", "version": version,
        "buildVersion": build, "minOSVersion": "17.0", "size": size, "sha256": sha,
        "entitlements": ["com.apple.developer.healthkit"],
        "privacy": {"NSHealthShareUsageDescription": "Reads your heart rate."},
    }


def config():
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "source.config.json"),
              encoding="utf-8") as handle:
        return json.load(handle)


class IPAInfoTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = make_ipa(os.path.join(self.directory.name, "HIIT-unsigned.ipa"))

    def write_entitlements(self, entitlements, prefix=b""):
        path = os.path.join(self.directory.name, "entitlements.plist")
        with open(path, "wb") as handle:
            handle.write(prefix + plistlib.dumps(entitlements))
        return path

    def test_reads_what_the_installer_will_verify(self):
        description = ipa_info.describe(self.ipa)
        self.assertEqual(description["bundleIdentifier"], BUNDLE)
        self.assertEqual(description["name"], "HIIT Coach")
        self.assertEqual(description["version"], "1.0.31")
        self.assertEqual(description["buildVersion"], "57")
        self.assertEqual(description["minOSVersion"], "17.0")
        self.assertEqual(description["sdk"], "iphoneos27.1")
        self.assertEqual(description["size"], os.path.getsize(self.ipa))
        with open(self.ipa, "rb") as handle:
            self.assertEqual(description["sha256"], hashlib.sha256(handle.read()).hexdigest())
        self.assertEqual(description["extensions"], [BUNDLE + ".HIITWidgets"])
        self.assertEqual(description["ipaName"], "HIIT-unsigned.ipa")

    def test_privacy_keys_come_from_the_app_and_its_extensions_only(self):
        privacy = ipa_info.describe(self.ipa)["privacy"]
        self.assertEqual(sorted(privacy), [
            "NSBluetoothAlwaysUsageDescription",
            "NSHealthShareUsageDescription",
            "NSHealthUpdateUsageDescription",  # declared by the extension
        ])
        self.assertNotIn("NSCameraUsageDescription", privacy)  # a framework's plist is not the app's
        self.assertNotIn("NSSupportsLiveActivities", privacy)

    def test_entitlements_skip_signer_specific_keys(self):
        path = self.write_entitlements({
            "com.apple.developer.healthkit": True,
            "application-identifier": "TEAM.com.scootsy.HIIT",
            "com.apple.developer.team-identifier": "TEAM",
            "get-task-allow": False,
        })
        self.assertEqual(ipa_info.describe(self.ipa, [path])["entitlements"], ["com.apple.developer.healthkit"])

    def test_entitlements_tolerate_codesign_noise_and_unsigned_binaries(self):
        noisy = self.write_entitlements({"com.apple.developer.healthkit": True},
                                        prefix=b"Executable=/path/HIIT.app/HIIT\n")
        self.assertEqual(ipa_info.describe(self.ipa, [noisy])["entitlements"], ["com.apple.developer.healthkit"])
        empty = os.path.join(self.directory.name, "empty.plist")
        open(empty, "wb").close()
        self.assertEqual(ipa_info.describe(self.ipa, [empty])["entitlements"], [])

    def test_debuggable_builds_list_get_task_allow(self):
        path = self.write_entitlements({"get-task-allow": True})
        self.assertEqual(ipa_info.describe(self.ipa, [path])["entitlements"], ["get-task-allow"])

    def test_extension_version_must_match_the_app(self):
        bad = make_ipa(os.path.join(self.directory.name, "bad.ipa"), extension_version="1.0")
        with self.assertRaisesRegex(ipa_info.IPAError, "mismatched extensions"):
            ipa_info.describe(bad)

    def test_rejects_things_that_are_not_ipas(self):
        not_zip = os.path.join(self.directory.name, "nope.ipa")
        with open(not_zip, "w") as handle:
            handle.write("hello")
        with self.assertRaises(ipa_info.IPAError):
            ipa_info.describe(not_zip)
        empty_zip = os.path.join(self.directory.name, "empty.ipa")
        with zipfile.ZipFile(empty_zip, "w") as archive:
            archive.writestr("README", "no payload")
        with self.assertRaisesRegex(ipa_info.IPAError, "exactly one app"):
            ipa_info.describe(empty_zip)

    def test_check_catches_a_build_that_missed_its_version_stamp(self):
        description = ipa_info.describe(self.ipa)
        ipa_info.check(description, "1.0.31", "57", "27.1", require_orientations=True)  # the good case
        with self.assertRaisesRegex(ipa_info.IPAError, "version override"):
            ipa_info.check(description, expect_version="1.0.32")
        with self.assertRaisesRegex(ipa_info.IPAError, "build-number override"):
            ipa_info.check(description, expect_build="58")

    def test_check_requires_a_semantic_version(self):
        two_part = ipa_info.describe(make_ipa(os.path.join(self.directory.name, "two.ipa"), version="1.0"))
        with self.assertRaisesRegex(ipa_info.IPAError, "MAJOR.MINOR.PATCH"):
            ipa_info.check(two_part)

    def test_check_requires_the_duo_sdk(self):
        for sdk in ("iphoneos18.5", "iphoneos26.4", "iphoneos27.0", ""):
            old = ipa_info.describe(make_ipa(os.path.join(self.directory.name, "old.ipa"), sdk=sdk))
            with self.assertRaisesRegex(ipa_info.IPAError, "letterboxed"):
                ipa_info.check(old, min_sdk="27.1")
        for sdk in ("iphoneos27.1", "iphoneos27.2", "iphoneos28.0"):
            new = ipa_info.describe(make_ipa(os.path.join(self.directory.name, "new.ipa"), sdk=sdk))
            ipa_info.check(new, min_sdk="27.1")

    def test_check_requires_every_orientation(self):
        portrait = ipa_info.describe(make_ipa(os.path.join(self.directory.name, "portrait.ipa"),
                                              orientations=["UIInterfaceOrientationPortrait"]))
        with self.assertRaisesRegex(ipa_info.IPAError, "inner display"):
            ipa_info.check(portrait, require_orientations=True)

    def test_orientations_are_read_from_the_iphone_specific_key_too(self):
        # What Xcode generates from INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone.
        path = os.path.join(self.directory.name, "suffixed.ipa")
        info = {
            "CFBundleIdentifier": BUNDLE, "CFBundleShortVersionString": "1.0.31", "CFBundleVersion": "57",
            "MinimumOSVersion": "17.0", "DTSDKName": "iphoneos27.1",
            "UISupportedInterfaceOrientations~iphone": ALL_ORIENTATIONS,
            "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait"],
        }
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/HIIT.app/Info.plist", plistlib.dumps(info))
        description = ipa_info.describe(path)
        self.assertEqual(description["orientations"], sorted(ALL_ORIENTATIONS))
        ipa_info.check(description, require_orientations=True)

    def test_command_line_writes_json_and_fails_loudly(self):
        output = os.path.join(self.directory.name, "release.json")
        with contextlib.redirect_stdout(io.StringIO()):
            status = ipa_info.main([self.ipa, "--expect-version", "1.0.31", "--expect-build", "57",
                                    "--min-sdk", "27.1", "--require-all-orientations", "-o", output])
        self.assertEqual(status, 0)
        with open(output, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["version"], "1.0.31")
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(ipa_info.main([self.ipa, "--expect-version", "9.9.9", "-o", output]), 1)
        self.assertIn("9.9.9", errors.getvalue())


class BuildSourceTests(unittest.TestCase):
    def build(self, releases, metadata_by_tag=None, existing=None, pending=None, overrides=None):
        settings = config()
        settings.update(overrides or {})
        metadata_by_tag = metadata_by_tag or {}
        self.requested = []

        def metadata_for(item):
            self.requested.append(item["tag_name"])
            return metadata_by_tag.get(item["tag_name"])

        return build_source.build(settings, REPO, "altstore", releases, existing=existing,
                                  metadata_for=metadata_for, pending=pending)

    def assert_loads(self, document):
        self.assertEqual(build_source.validate(document), [])
        sidestore_decode(document)
        livecontainer_decode(document)

    def test_releases_from_before_the_feed_are_left_out(self):
        releases = [release("v1.0.30", "2026-08-12T16:34:43Z", ipa_size=900, metadata=False),
                    release("v1.0.27", "2026-08-08T21:52:05Z", ipa_size=900, metadata=False)]
        document, report = self.build(releases)
        self.assertEqual(document["apps"], [])
        self.assertEqual(document["featuredApps"], [])
        self.assertEqual(self.requested, [])
        self.assertTrue(any("before the feed existed" in line for line in report))
        self.assert_loads(document)

    def test_a_release_with_metadata_becomes_a_version(self):
        releases = [release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=1234),
                    release("v1.0.30", "2026-08-12T16:34:43Z", ipa_size=900, metadata=False)]
        document, _ = self.build(releases, {"v1.0.31": metadata("1.0.31", "57", 1234)})
        self.assert_loads(document)
        app = document["apps"][0]
        self.assertEqual(app["bundleIdentifier"], BUNDLE)
        self.assertEqual(len(app["versions"]), 1)
        entry = app["versions"][0]
        self.assertEqual(entry, {
            "version": "1.0.31", "buildVersion": "57", "buildNumber": "57",
            "date": "2026-11-16T05:00:00Z", "localizedDescription": "Faster warm-ups.",
            "downloadURL": f"https://github.com/{REPO}/releases/download/v1.0.31/HIIT-unsigned.ipa",
            "size": 1234, "sha256": "ab" * 32, "minOSVersion": "17.0",
        })
        self.assertEqual(app["appPermissions"]["entitlements"], ["com.apple.developer.healthkit"])
        self.assertIn("NSHealthShareUsageDescription", app["appPermissions"]["privacy"])
        self.assertEqual(app["version"], "1.0.31")
        self.assertEqual(app["downloadURL"], entry["downloadURL"])
        self.assertEqual(document["sourceURL"], f"https://raw.githubusercontent.com/{REPO}/altstore/apps.json")
        self.assertEqual(document["featuredApps"], [BUNDLE])

    def test_versions_are_newest_first_whatever_order_the_api_returns(self):
        releases = [release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10),
                    release("v1.0.33", "2026-11-20T05:00:00Z", ipa_size=30),
                    release("v1.0.32", "2026-11-18T05:00:00Z", ipa_size=20)]
        document, _ = self.build(releases, {
            "v1.0.31": metadata("1.0.31", "57", 10), "v1.0.32": metadata("1.0.32", "58", 20),
            "v1.0.33": metadata("1.0.33", "60", 30)})
        self.assert_loads(document)
        self.assertEqual([v["version"] for v in document["apps"][0]["versions"]], ["1.0.33", "1.0.32", "1.0.31"])
        self.assertEqual(document["apps"][0]["version"], "1.0.33")

    def test_published_versions_are_reused_without_downloading_again(self):
        first, _ = self.build([release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10)],
                              {"v1.0.31": metadata("1.0.31", "57", 10)})
        releases = [release("v1.0.32", "2026-11-18T05:00:00Z", ipa_size=20),
                    release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10, body="Edited notes.")]
        second, _ = self.build(releases, {"v1.0.32": metadata("1.0.32", "58", 20)}, existing=first)
        self.assertEqual(self.requested, ["v1.0.32"])  # only the new release was fetched
        self.assert_loads(second)
        versions = second["apps"][0]["versions"]
        self.assertEqual([v["version"] for v in versions], ["1.0.32", "1.0.31"])
        self.assertEqual(versions[1]["sha256"], "ab" * 32)
        self.assertEqual(versions[1]["localizedDescription"], "Edited notes.")  # notes follow the release

    def test_permissions_survive_a_run_with_nothing_new(self):
        releases = [release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10)]
        first, _ = self.build(releases, {"v1.0.31": metadata("1.0.31", "57", 10)})
        second, _ = self.build(releases, {}, existing=first)
        self.assertEqual(self.requested, [])
        self.assertEqual(second["apps"][0]["appPermissions"], first["apps"][0]["appPermissions"])
        self.assertEqual(second, first)

    def test_a_deleted_release_leaves_the_feed(self):
        both = [release("v1.0.32", "2026-11-18T05:00:00Z", ipa_size=20),
                release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10)]
        first, _ = self.build(both, {"v1.0.31": metadata("1.0.31", "57", 10),
                                     "v1.0.32": metadata("1.0.32", "58", 20)})
        second, _ = self.build(both[1:], {}, existing=first)
        self.assertEqual([v["version"] for v in second["apps"][0]["versions"]], ["1.0.31"])
        self.assertEqual(second["apps"][0]["version"], "1.0.31")
        self.assert_loads(second)

    def test_a_swapped_ipa_is_not_served_from_the_cache_or_listed(self):
        first, _ = self.build([release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10)],
                              {"v1.0.31": metadata("1.0.31", "57", 10)})
        # Someone replaced the IPA on the release: the size no longer matches.
        swapped = [release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=11)]
        document, report = self.build(swapped, {"v1.0.31": metadata("1.0.31", "57", 10)}, existing=first)
        self.assertEqual(self.requested, ["v1.0.31"])
        self.assertEqual(document["apps"], [])
        self.assertTrue(any("11 bytes" in line for line in report))

    def test_unusable_releases_are_skipped_with_a_reason(self):
        releases = [
            release("v2.0.0", "2026-12-01T00:00:00Z", ipa_size=10, draft=True),
            release("v2.0.1", "2026-12-02T00:00:00Z", ipa_size=10, prerelease=True),
            release("v2.0.2", "2026-12-03T00:00:00Z", ipa_size=None),
            release("v2.0.3", "2026-12-04T00:00:00Z", ipa_size=10),          # metadata can't be downloaded
            release("v2.0.4", "2026-12-05T00:00:00Z", ipa_size=10),          # wrong app
            release("v2.0.5", "2026-12-06T00:00:00Z", ipa_size=10),          # two-part version
            release("v2.0.6", "not-a-date", ipa_size=10),
        ]
        wrong_app = metadata("2.0.4", "70", 10)
        wrong_app["bundleIdentifier"] = "com.someone.else"
        document, report = self.build(releases, {"v2.0.4": wrong_app, "v2.0.5": metadata("2.0", "71", 10)})
        self.assertEqual(document["apps"], [])
        text = "\n".join(report)
        for expected in ("draft or pre-release", "no IPA attached", "couldn't be read",
                         "com.someone.else", "MAJOR.MINOR.PATCH", "publish date"):
            self.assertIn(expected, text)
        self.assert_loads(document)

    def test_duplicate_versions_keep_the_newest_release(self):
        releases = [release("v1.0.31-b", "2026-11-17T05:00:00Z", ipa_size=12),
                    release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10)]
        document, _ = self.build(releases, {"v1.0.31": metadata("1.0.31", "57", 10),
                                            "v1.0.31-b": metadata("1.0.31", "57", 12)})
        versions = document["apps"][0]["versions"]
        self.assertEqual(len(versions), 1)
        self.assertEqual(versions[0]["size"], 12)
        self.assert_loads(document)

    def test_history_is_capped(self):
        releases, by_tag = [], {}
        for patch in range(1, 9):
            tag = f"v1.0.{patch}"
            releases.append(release(tag, f"2026-11-{patch:02d}T05:00:00Z", ipa_size=patch))
            by_tag[tag] = metadata(f"1.0.{patch}", str(patch), patch)
        document, _ = self.build(releases, by_tag, overrides={"maxVersions": 3})
        self.assertEqual([v["version"] for v in document["apps"][0]["versions"]], ["1.0.8", "1.0.7", "1.0.6"])
        self.assert_loads(document)

    def test_a_pull_request_build_previews_as_the_newest_version(self):
        releases = [release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10)]
        pending = {"metadata": metadata("1.0.32", "58", 20), "tag": "v1.0.32", "date": "2026-11-18T05:00:00Z",
                   "notes": "Preview.", "downloadURL": f"https://github.com/{REPO}/releases/download/v1.0.32/HIIT-unsigned.ipa"}
        document, report = self.build(releases, {"v1.0.31": metadata("1.0.31", "57", 10)}, pending=pending)
        self.assert_loads(document)
        self.assertEqual([v["version"] for v in document["apps"][0]["versions"]], ["1.0.32", "1.0.31"])
        self.assertIn("not yet released", report[0])
        bad = dict(pending, metadata={"version": "1.0"})
        with self.assertRaises(ValueError):
            self.build(releases, {}, pending=bad)

    def test_notes_stop_at_the_install_marker(self):
        self.assertEqual(build_source.notes_from_body("Fixed the ring.\n\n<!-- install -->\nboilerplate"), "Fixed the ring.")
        self.assertEqual(build_source.notes_from_body("Just notes"), "Just notes")
        self.assertEqual(build_source.notes_from_body(""), "Maintenance build.")
        self.assertEqual(build_source.notes_from_body(None), "Maintenance build.")
        self.assertEqual(build_source.notes_from_body("<!-- install -->\nonly boilerplate"), "Maintenance build.")

    def test_validate_names_what_would_break_an_installer(self):
        document, _ = self.build([release("v1.0.32", "2026-11-18T05:00:00Z", ipa_size=20),
                                  release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=10)],
                                 {"v1.0.31": metadata("1.0.31", "57", 10), "v1.0.32": metadata("1.0.32", "58", 20)})
        self.assertEqual(build_source.validate(document), [])

        def problems_after(mutate):
            broken = json.loads(json.dumps(document))
            mutate(broken)
            return "\n".join(build_source.validate(broken))

        self.assertIn("six hex digits", problems_after(lambda d: d.__setitem__("tintColor", "#FF5F44")))
        self.assertIn("source.name", problems_after(lambda d: d.pop("name")))
        self.assertIn("no versions", problems_after(lambda d: d["apps"][0].__setitem__("versions", [])))
        self.assertIn("newest first", problems_after(lambda d: d["apps"][0]["versions"].reverse()))
        self.assertIn("sha256", problems_after(lambda d: d["apps"][0]["versions"][0].__setitem__("sha256", "XYZ")))
        self.assertIn("size", problems_after(lambda d: d["apps"][0]["versions"][0].__setitem__("size", "20")))
        self.assertIn("isn't YYYY", problems_after(
            lambda d: d["apps"][0]["versions"][0].__setitem__("date", "2026-11-18T05:00:00.123Z")))
        self.assertIn("https URL", problems_after(
            lambda d: d["apps"][0]["versions"][0].__setitem__("downloadURL", "http://example.com/a.ipa")))
        self.assertIn("buildNumber", problems_after(lambda d: d["apps"][0]["versions"][0].pop("buildNumber")))
        self.assertIn("developerName", problems_after(lambda d: d["apps"][0].pop("developerName")))
        self.assertIn("doesn't match the newest", problems_after(lambda d: d["apps"][0].__setitem__("version", "0.0.1")))
        self.assertIn("category", problems_after(lambda d: d["apps"][0].__setitem__("category", "fitness")))
        self.assertIn("featuredApps", problems_after(lambda d: d.__setitem__("featuredApps", ["com.other.app"])))

    def test_the_shipped_config_produces_a_loadable_source(self):
        settings = config()
        self.assertEqual(settings["app"]["bundleIdentifier"], BUNDLE)
        self.assertRegex(settings["source"]["tintColor"], r"^[0-9A-Fa-f]{6}$")
        self.assertIn(settings["app"]["category"], build_source.CATEGORIES)

    def test_command_line_end_to_end(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = make_ipa(os.path.join(directory, "HIIT-unsigned.ipa"))
            described = ipa_info.describe(ipa)
            os.mkdir(os.path.join(directory, "meta"))
            with open(os.path.join(directory, "meta", "v1.0.31.json"), "w", encoding="utf-8") as handle:
                json.dump(described, handle)
            releases_path = os.path.join(directory, "releases.json")
            with open(releases_path, "w", encoding="utf-8") as handle:
                # `gh api --paginate --slurp` shape: a list of pages.
                json.dump([[release("v1.0.31", "2026-11-16T05:00:00Z", ipa_size=described["size"])],
                           [release("v1.0.30", "2026-08-12T16:34:43Z", ipa_size=900, metadata=False)]], handle)
            output = os.path.join(directory, "apps.json")
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                status = build_source.main(["--repo", REPO, "--releases", releases_path,
                                            "--metadata-dir", os.path.join(directory, "meta"), "-o", output])
            self.assertEqual(status, 0, printed.getvalue())
            with open(output, encoding="utf-8") as handle:
                document = json.load(handle)
            self.assert_loads(document)
            # The installer's own checks against the real file.
            sidestore_verify_download(document["apps"][0]["versions"][0], ipa, BUNDLE)

            # Preview mode: the same feed plus an unreleased build.
            pending_path = os.path.join(directory, "pending.json")
            newer = ipa_info.describe(make_ipa(os.path.join(directory, "next.ipa"), version="1.0.32", build="58"))
            with open(pending_path, "w", encoding="utf-8") as handle:
                json.dump(newer, handle)
            with contextlib.redirect_stdout(io.StringIO()):
                status = build_source.main(["--repo", REPO, "--releases", releases_path, "--existing", output,
                                            "--pending", pending_path, "--pending-tag", "v1.0.32",
                                            "--pending-date", "2026-11-18T05:00:00Z", "-o", output])
            self.assertEqual(status, 0)
            with open(output, encoding="utf-8") as handle:
                preview = json.load(handle)
            self.assertEqual([v["version"] for v in preview["apps"][0]["versions"]], ["1.0.32", "1.0.31"])
            self.assertTrue(sidestore_has_update("1.0.31", preview))
            self.assertFalse(sidestore_has_update("1.0.32", preview))

    def test_command_line_rejects_bad_input(self):
        with tempfile.TemporaryDirectory() as directory:
            releases_path = os.path.join(directory, "releases.json")
            with open(releases_path, "w", encoding="utf-8") as handle:
                json.dump({"message": "Not Found"}, handle)
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                status = build_source.main(["--repo", REPO, "--releases", releases_path,
                                            "-o", os.path.join(directory, "apps.json")])
            self.assertEqual(status, 1)
            self.assertIn("isn't a JSON array", errors.getvalue())


# --- What the installers do with the feed ------------------------------------
#
# Ported from SideStore (AltStore/Core/Model/{Source,StoreApp,AppVersion}.swift,
# FetchSourceOperation, VerifyAppOperation, InstalledApp.hasUpdate) and
# LiveContainer (LCAltStoreSourcesView.swift) as of November 2026.

def _iso8601(text):
    # SideStore: ISO8601DateFormatter with full date, full time and time zone;
    # falls back to a bare date. Fractional seconds do not parse.
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})", text):
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
        return datetime.fromisoformat(text)
    raise AssertionError(f"SideStore can't parse the date {text!r}")


def _hex_color(text):
    stripped = re.sub(r"[^0-9A-Za-z]", "", text)  # trims non-alphanumerics
    assert len(stripped) in (3, 6, 8) and re.fullmatch(r"[0-9A-Fa-f]+", stripped), f"invalid tint {text!r}"


def _url(text):
    assert isinstance(text, str) and re.match(r"^https?://\S+$", text), f"not a URL: {text!r}"


def sidestore_decode(document):
    """Raise AssertionError where SideStore's decoder would throw."""
    assert isinstance(document["name"], str)
    if "tintColor" in document:
        _hex_color(document["tintColor"])
    for key in ("iconURL", "website", "headerURL"):
        if key in document:
            _url(document[key])
    for app in document.get("apps", []):
        for key in ("name", "bundleIdentifier", "developerName", "localizedDescription"):
            assert isinstance(app[key], str), f"app.{key} is required"
        _url(app["iconURL"])
        if "tintColor" in app:
            _hex_color(app["tintColor"])
        assert "marketplaceID" not in app
        versions = app.get("versions")
        assert versions, "MergeError.noVersions: an app needs at least one version"
        for entry in versions:
            assert isinstance(entry["version"], str)
            assert entry.get("buildVersion") is None or isinstance(entry["buildVersion"], str)
            _iso8601(entry["date"])
            _url(entry["downloadURL"])
            assert isinstance(entry["size"], int) and not isinstance(entry["size"], bool)
            assert entry.get("sha256") is None or isinstance(entry["sha256"], str)
        permissions = app.get("appPermissions")
        if permissions is not None:
            assert all(isinstance(item, str) for item in permissions.get("entitlements", []))
            assert all(isinstance(k, str) and isinstance(v, str) for k, v in permissions.get("privacy", {}).items())
    for identifier in document.get("featuredApps", []):
        assert isinstance(identifier, str)


def sidestore_verify_download(entry, ipa_path, expected_bundle):
    """VerifyAppOperation: bundle id, checksum, size, version and build."""
    with zipfile.ZipFile(ipa_path) as archive:
        info = plistlib.loads(archive.read("Payload/HIIT.app/Info.plist"))
    assert info["CFBundleIdentifier"] == expected_bundle, "mismatchedBundleIdentifiers"
    with open(ipa_path, "rb") as handle:
        assert hashlib.sha256(handle.read()).hexdigest() == entry["sha256"].lower(), "mismatchedHash"
    assert os.path.getsize(ipa_path) == entry["size"], "mismatchedSize"
    assert entry["buildVersion"] == info["CFBundleVersion"], "mismatchedBuildVersion"
    assert entry["version"] == info["CFBundleShortVersionString"], "mismatchedVersion"


def sidestore_has_update(installed_version, document):
    """InstalledApp.hasUpdate: compares MAJOR.MINOR.PATCH numerically."""
    latest = document["apps"][0]["versions"][0]["version"]

    def semantic(text):
        match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", text)
        assert match, f"{text!r} isn't a semantic version - SideStore falls back to string matching"
        return tuple(int(part) for part in match.groups())

    return semantic(latest) > semantic(installed_version)


def livecontainer_decode(document):
    """LiveContainer needs a name, and installs versions[0].downloadURL."""
    assert isinstance(document.get("name"), str), "lc.sources.error.malformed"
    for app in document.get("apps") or []:
        if not (app.get("name") and app.get("bundleIdentifier")):
            continue
        versions = [v for v in app.get("versions") or [] if v.get("version") and v.get("downloadURL")]
        assert versions, "LiveContainer would find nothing to install"
        latest = versions[0]
        assert latest == max(versions, key=lambda v: v["date"]), "LiveContainer installs the first entry"
        assert latest.get("buildNumber"), "LiveContainer reads the build from buildNumber"
        # ISO8601DateFormatter() with default options: no fractional seconds.
        assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", latest["date"]), latest["date"]


if __name__ == "__main__":
    unittest.main()
