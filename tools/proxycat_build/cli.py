"""Command-line interface for ``build.py``."""

from __future__ import annotations

import argparse
import os
import sys

from . import __version__
from . import assets, clean, doctor, mihomo, project, xcode
from .app_icon import write as write_app_icon
from .config import ROOT, BuildError
from .process import capture
from .versions import build_number, marketing_version

_EPILOG = """\
Examples:
  python3 build.py mihomo-init
  python3 build.py assets
  python3 build.py all
  python3 build.py libmihomo --target sim
  python3 build.py libmihomo-obf --garble-flags="-literals -tiny"
  python3 build.py project --team ABCDE12345
  python3 build.py sim
  python3 build.py build --team ABCDE12345
  python3 build.py doctor
"""


def _add_mihomo_build_options(parser: argparse.ArgumentParser, *, target: bool) -> None:
    if target:
        parser.add_argument(
            "--target",
            choices=("all", "device", "sim"),
            default="all",
            help="slice set to build (default: all)",
        )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--obfuscate",
        dest="obfuscate",
        action="store_true",
        help="build through garble",
    )
    group.add_argument(
        "--no-obfuscate",
        dest="obfuscate",
        action="store_false",
        help="force a plain build",
    )
    parser.set_defaults(obfuscate=None)
    parser.add_argument(
        "--garble-flags",
        default=None,
        help='extra garble flags, e.g. "-literals -tiny"',
    )
    parser.add_argument(
        "--gomobile",
        default=None,
        help="gomobile executable (default: $GOMOBILE or gomobile)",
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="build.py",
        description="ProxyCat build tool (replaces the former Makefile + shell scripts).",
        epilog=_EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command", metavar="command")

    sub.add_parser("version", help="print marketing version, build number, git describe")
    sub.add_parser("doctor", help="check build prerequisites and generated artifacts")

    p = sub.add_parser("project", help="generate ProxyCat.xcodeproj with xcodegen")
    p.add_argument("--team", default=None, help="Apple development team ID")
    p.add_argument(
        "xcodegen_args",
        nargs=argparse.REMAINDER,
        help="extra arguments forwarded to `xcodegen generate` (use after --)",
    )

    p = sub.add_parser("libmihomo", help="build Frameworks/Libmihomo.xcframework")
    _add_mihomo_build_options(p, target=True)

    p = sub.add_parser("libmihomo-obf", help="obfuscated libmihomo build")
    _add_mihomo_build_options(p, target=False)

    p = sub.add_parser("all", help="mihomo-init + libmihomo + project")
    _add_mihomo_build_options(p, target=False)

    p = sub.add_parser("all-obf", help="mihomo-init + obfuscated libmihomo + project")
    _add_mihomo_build_options(p, target=False)

    sub.add_parser("mihomo-init", help="initialize the mihomo submodule")
    sub.add_parser("mihomo-upgrade", help="checkout origin/Meta and rebuild")
    p = sub.add_parser("mihomo-checkout", help="pin mihomo to a ref and rebuild")
    p.add_argument("ref", help="tag, commit or branch in the mihomo submodule")

    p = sub.add_parser("assets", help="download geo databases and/or external UI")
    p.add_argument(
        "kind",
        nargs="?",
        choices=("all", "geo", "ui"),
        default="all",
        help="asset subset (default: all)",
    )
    sub.add_parser("geo-assets", help="alias for `assets geo`")
    sub.add_parser("ui-assets", help="alias for `assets ui`")
    sub.add_parser("clean-assets", help="empty BundledAssets/{geo,ui}")

    p = sub.add_parser("build", help="signed device build")
    p.add_argument("--team", default=None, help="Apple development team ID")
    p.add_argument("--configuration", default=None, help="xcodebuild configuration")
    p.add_argument("--scheme", default=None, help="xcodebuild scheme")
    p.add_argument("--destination", default=None, help="xcodebuild destination")

    p = sub.add_parser("sim", help="unsigned iOS Simulator build")
    p.add_argument("--configuration", default=None, help="xcodebuild configuration")
    p.add_argument("--scheme", default=None, help="xcodebuild scheme")
    p.add_argument("--destination", default=None, help="xcodebuild destination")

    sub.add_parser("clean", help="remove generated artifacts")
    sub.add_parser("app-icon", help="render the 1024x1024 app icon (requires Pillow)")

    return parser


def _print_version() -> None:
    try:
        describe = capture(
            ["git", "describe", "--tags", "--always", "--dirty"], cwd=ROOT
        )
    except BuildError:
        describe = None
    team = os.environ.get("XCODE_DEVELOPMENT_TEAM") or "<unset>"
    print(f"MARKETING_VERSION  {marketing_version()}")
    print(f"BUILD_NUMBER       {build_number()}")
    print(f"GIT_DESCRIBE       {describe or 'unknown'}")
    print(f"DEVELOPMENT_TEAM   {team}")


def _build_libmihomo(args: argparse.Namespace, *, force_obfuscate: bool | None = None) -> None:
    mihomo.build(
        target=getattr(args, "target", "all"),
        obfuscate=force_obfuscate if force_obfuscate is not None else args.obfuscate,
        garble_flags=args.garble_flags,
        gomobile=args.gomobile,
    )


def _all(args: argparse.Namespace, *, force_obfuscate: bool | None = None) -> None:
    mihomo.initialize()
    _build_libmihomo(args, force_obfuscate=force_obfuscate)
    project.generate()


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0

    try:
        match args.command:
            case "version":
                _print_version()
            case "doctor":
                return doctor.doctor()
            case "project":
                extras = list(args.xcodegen_args)
                if extras[:1] == ["--"]:
                    extras = extras[1:]
                project.generate(*extras, team=args.team)
            case "libmihomo":
                _build_libmihomo(args)
            case "libmihomo-obf":
                _build_libmihomo(args, force_obfuscate=True)
            case "all":
                _all(args)
            case "all-obf":
                _all(args, force_obfuscate=True)
            case "mihomo-init":
                mihomo.initialize()
            case "mihomo-upgrade":
                mihomo.upgrade()
            case "mihomo-checkout":
                mihomo.checkout(args.ref)
            case "assets":
                assets.fetch(args.kind)
            case "geo-assets":
                assets.fetch("geo")
            case "ui-assets":
                assets.fetch("ui")
            case "clean-assets":
                assets.clean()
            case "build":
                xcode.build_device(
                    configuration=args.configuration,
                    scheme=args.scheme,
                    destination=args.destination,
                    team=args.team,
                )
            case "sim":
                xcode.build_simulator(
                    configuration=args.configuration,
                    scheme=args.scheme,
                    destination=args.destination,
                )
            case "clean":
                clean.clean()
            case "app-icon":
                write_app_icon()
            case _:  # pragma: no cover - argparse prevents this
                parser.error(f"unknown command: {args.command}")
    except BuildError as error:
        print(f"error: {error}", file=sys.stderr)
        return error.exit_code
    except KeyboardInterrupt:  # pragma: no cover
        print("\ninterrupted", file=sys.stderr)
        return 130

    return 0
