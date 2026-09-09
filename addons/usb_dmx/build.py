#!/usr/bin/env python3
"""Build the usb_dmx GDExtension.

Clones godot-cpp next to this file (once), then runs SCons for the current
platform. Needs: git, a C++ toolchain (MSVC "Desktop development with C++"
on Windows, clang/gcc elsewhere), and SCons (`pip install scons`).

    python build.py                      # template_debug + template_release
    python build.py --target template_debug
    python build.py --godot-cpp-branch 4.5
"""
import argparse
import platform
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GODOT_CPP = HERE / "godot-cpp"
GODOT_CPP_REPO = "https://github.com/godotengine/godot-cpp.git"


def sh(args, **kw):
    print("  $", " ".join(str(a) for a in args))
    subprocess.check_call(args, **kw)


def ensure_godot_cpp(branch: str):
    if not (GODOT_CPP / "SConstruct").exists():
        print(f"cloning godot-cpp ({branch})... (the first build compiles all of "
              "godot-cpp — ~15-20 min; later builds are seconds)")
        sh(["git", "clone", "--depth", "1", "--branch", branch, GODOT_CPP_REPO, str(GODOT_CPP)])
    # keep Godot's editor from scanning godot-cpp's thousands of files
    (GODOT_CPP / ".gdignore").touch()


def detect_platform() -> str:
    s = platform.system().lower()
    return {"windows": "windows", "linux": "linux", "darwin": "macos"}.get(s, s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=["template_debug", "template_release"], action="append")
    ap.add_argument("--platform", default=detect_platform())
    ap.add_argument("--godot-cpp-branch", default="4.5")
    ap.add_argument("--jobs", "-j", default=str(__import__("os").cpu_count() or 4))
    args = ap.parse_args()

    ensure_godot_cpp(args.godot_cpp_branch)

    targets = args.target or ["template_debug", "template_release"]
    for target in targets:
        print(f"\n=== {args.platform} / {target} ===")
        sh([sys.executable, "-m", "SCons",
            f"platform={args.platform}", f"target={target}", f"-j{args.jobs}"],
           cwd=str(HERE))

    print("\nBuilt libraries in", HERE / "bin")
    for f in sorted((HERE / "bin").glob("*")):
        print("  ", f.name)

    # activate the extension (Godot ignores usb_dmx.gdextension.disabled)
    tmpl = HERE / "usb_dmx.gdextension.disabled"
    active = HERE / "usb_dmx.gdextension"
    if tmpl.exists() and not active.exists():
        active.write_text(tmpl.read_text())
        print(f"\nActivated {active.name} — reopen the Godot project.")


if __name__ == "__main__":
    main()
