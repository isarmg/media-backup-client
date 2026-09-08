#!/usr/bin/env python3
"""Exercise IPA layout, executable permissions and rejection before publication."""

import importlib.util
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
import zipfile

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("ipa", Path(__file__).with_name("package-ios-ipa.py"))
ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipa)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.app = Path(self.root.name) / "build" / "MediaBackup.app"
        self.app.mkdir(parents=True)
        self.output = Path(self.root.name) / "dist" / "media-backup-ios-0.4.0-unsigned.ipa"
        self.info = {
            "CFBundleIdentifier": "org.sarmg.mediabackup",
            "CFBundleShortVersionString": "0.4.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleExecutable": "MediaBackup",
        }
        self.write_info()
        (self.app / "MediaBackup").write_bytes(b"device executable fixture")
        (self.app / "MediaBackup").chmod(0o755)

    def write_info(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY))

    def test_standard_payload_preserves_binary_resources_and_links(self):
        (self.app / "照片.png").write_bytes(b"image fixture")
        (self.app / "resource-link").symlink_to("照片.png")
        ipa.package(self.app, self.output, "0.4.0")
        with zipfile.ZipFile(self.output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertTrue(all(name.startswith("Payload/MediaBackup.app") for name in archive.namelist()))
            self.assertEqual(archive.read("Payload/MediaBackup.app/照片.png"), b"image fixture")
            binary = archive.getinfo("Payload/MediaBackup.app/MediaBackup")
            self.assertEqual((binary.external_attr >> 16) & 0o777, 0o755)
            link = archive.getinfo("Payload/MediaBackup.app/resource-link")
            self.assertTrue(stat.S_ISLNK(link.external_attr >> 16))
            self.assertEqual(archive.read(link).decode(), "照片.png")

    def test_simulator_and_wrong_release_are_rejected(self):
        for field, value in [("CFBundleSupportedPlatforms", ["iPhoneSimulator"]),
                             ("CFBundleShortVersionString", "0.3.0"),
                             ("CFBundleIdentifier", "wrong.application")]:
            with self.subTest(field=field):
                original = self.info[field]
                self.info[field] = value
                self.write_info()
                with self.assertRaises(ValueError):
                    ipa.package(self.app, self.output, "0.4.0")
                self.assertFalse(self.output.exists())
                self.info[field] = original

    def test_missing_binary_and_external_links_are_rejected(self):
        (self.app / "MediaBackup").unlink()
        with self.assertRaises(ValueError):
            ipa.package(self.app, self.output, "0.4.0")
        (self.app / "MediaBackup").write_bytes(b"fixture")
        (self.app / "MediaBackup").chmod(0o755)
        (self.app / "outside").symlink_to(Path(self.root.name))
        with self.assertRaises(ValueError):
            ipa.package(self.app, self.output, "0.4.0")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
