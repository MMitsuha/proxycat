"""Unit tests for the pure helpers in tools.proxycat_build."""

from __future__ import annotations

import io
import tarfile
import tempfile
import unittest
from pathlib import Path

from tools.proxycat_build import assets, mihomo, versions
from tools.proxycat_build.cli import _parser
from tools.proxycat_build.config import BuildError


class VersionTests(unittest.TestCase):
    def test_marketing_version_reads_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "VERSION").write_text("2.3.4\n", encoding="utf-8")
            self.assertEqual(versions.marketing_version(root=root, env={}), "2.3.4")

    def test_marketing_version_env_wins(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "VERSION").write_text("2.3.4\n", encoding="utf-8")
            env = {"PROXYCAT_MARKETING_VERSION": "9.9.9"}
            self.assertEqual(versions.marketing_version(root=root, env=env), "9.9.9")

    def test_build_number_env_override(self) -> None:
        env = {"PROXYCAT_BUILD_NUMBER": "4242"}
        self.assertEqual(versions.build_number(env=env), "4242")

    def test_project_env_sets_team_and_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "VERSION").write_text("1.2.0\n", encoding="utf-8")
            env = versions.project_env(
                team="ABCDE12345",
                root=root,
                env={"PROXYCAT_BUILD_NUMBER": "7"},
            )
            self.assertEqual(env["PROXYCAT_MARKETING_VERSION"], "1.2.0")
            self.assertEqual(env["PROXYCAT_BUILD_NUMBER"], "7")
            self.assertEqual(env["XCODE_DEVELOPMENT_TEAM"], "ABCDE12345")

    def test_compose_ldflags_keeps_quoted_x_flags(self) -> None:
        flags = versions.compose_ldflags(
            version="v1.2.3",
            build_time="2026-01-02T03:04:05Z",
            wrapper_tag="with_gvisor with_low_memory +public",
            mihomo_commit="abc123",
            wrapper_commit="def456",
        )
        self.assertIn("-s -w", flags)
        self.assertIn("-X 'github.com/metacubex/mihomo/constant.Version=v1.2.3'", flags)
        self.assertIn("wrapperBuildTag=with_gvisor with_low_memory +public", flags)
        self.assertIn("mihomoCommit=abc123", flags)
        self.assertIn("wrapperCommit=def456", flags)


class AssetPlanTests(unittest.TestCase):
    def test_geo_plan_maps_asn_database(self) -> None:
        plan = assets.geo_plan("https://example.com/geo/")
        pairs = {(remote, local) for remote, local, _ in plan}
        self.assertIn(("GeoLite2-ASN.mmdb", "ASN.mmdb"), pairs)
        self.assertIn(("geoip.dat", "geoip.dat"), pairs)
        for remote, _, url in plan:
            self.assertEqual(url, f"https://example.com/geo/{remote}")

    def test_download_file_url_replaces_destination(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.bin"
            source.write_bytes(b"payload")
            destination = root / "nested" / "destination.bin"
            assets.download(source.as_uri(), destination)
            self.assertEqual(destination.read_bytes(), b"payload")
            self.assertFalse(destination.with_name("destination.bin.tmp").exists())

    def test_tarball_extraction_rejects_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "evil.tgz"
            with tarfile.open(archive, "w:gz") as tar:
                info = tarfile.TarInfo("../escaped.txt")
                data = b"nope"
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            with self.assertRaises(BuildError):
                assets._extract_tarball(archive, root / "out")

    def test_tarball_extraction_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / "ui.tgz"
            with tarfile.open(archive, "w:gz") as tar:
                info = tarfile.TarInfo("dist/index.html")
                data = b"<html></html>"
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            destination = root / "out"
            assets._extract_tarball(archive, destination)
            self.assertEqual(
                (destination / "dist" / "index.html").read_bytes(), b"<html></html>"
            )


class GarbleTests(unittest.TestCase):
    def test_parse_garble_flags(self) -> None:
        self.assertEqual(
            mihomo.parse_garble_flags("  -literals   -tiny "),
            ["-literals", "-tiny"],
        )
        self.assertEqual(mihomo.parse_garble_flags(None), [])


class CliParserTests(unittest.TestCase):
    def test_libmihomo_options(self) -> None:
        args = _parser().parse_args(
            ["libmihomo", "--target", "sim", "--obfuscate", "--garble-flags=-literals"]
        )
        self.assertEqual(args.command, "libmihomo")
        self.assertEqual(args.target, "sim")
        self.assertTrue(args.obfuscate)
        self.assertEqual(args.garble_flags, "-literals")

    def test_obfuscation_defaults_to_env(self) -> None:
        args = _parser().parse_args(["libmihomo"])
        self.assertIsNone(args.obfuscate)

    def test_build_requires_no_positional(self) -> None:
        args = _parser().parse_args(["build", "--team", "ABCDE12345"])
        self.assertEqual(args.command, "build")
        self.assertEqual(args.team, "ABCDE12345")


if __name__ == "__main__":
    unittest.main()
