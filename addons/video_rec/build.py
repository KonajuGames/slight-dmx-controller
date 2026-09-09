#!/usr/bin/env python3
"""Build the video_rec GDExtension (minih264 + minimp4).

Reuses addons/usb_dmx/godot-cpp if it's already been cloned, otherwise
clones godot-cpp here. Needs git, Python 3, SCons, and a C++ toolchain
(MSVC "Desktop development with C++" on Windows).

    python build.py
    python build.py --target template_debug
"""
import argparse
import platform
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCAL_CPP = HERE / "godot-cpp"
GODOT_CPP_REPO = "https://github.com/godotengine/godot-cpp.git"


def sh(args, **kw):
    print("  $", " ".join(str(a) for a in args))
    subprocess.check_call(args, **kw)


def godot_cpp_dir(branch: str) -> Path:
    # Each extension keeps its own godot-cpp — SCons's signature DB is
    # per-build, so a shared checkout just gets recompiled anyway.
    if not (LOCAL_CPP / "SConstruct").exists():
        shared = HERE.parent / "usb_dmx" / "godot-cpp"
        if (shared / ".git").exists():
            print("copying godot-cpp from addons/usb_dmx ...")
            subprocess.check_call(["git", "clone", "--depth", "1", str(shared), str(LOCAL_CPP)])
        else:
            print(f"cloning godot-cpp ({branch})... first build compiles all of it (~15-20 min)")
            sh(["git", "clone", "--depth", "1", "--branch", branch, GODOT_CPP_REPO, str(LOCAL_CPP)])
    (LOCAL_CPP / ".gdignore").touch()
    return LOCAL_CPP


def detect_platform() -> str:
    return {"windows": "windows", "linux": "linux", "darwin": "macos"}.get(
        platform.system().lower(), platform.system().lower())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=["template_debug", "template_release"], action="append")
    ap.add_argument("--platform", default=detect_platform())
    ap.add_argument("--godot-cpp-branch", default="4.5")
    ap.add_argument("--jobs", "-j", default=str(__import__("os").cpu_count() or 4))
    args = ap.parse_args()

    cpp = godot_cpp_dir(args.godot_cpp_branch)
    for target in (args.target or ["template_debug", "template_release"]):
        print(f"\n=== {args.platform} / {target}  (godot-cpp: {cpp}) ===")
        sh([sys.executable, "-m", "SCons", f"godot_cpp={cpp.as_posix()}",
            f"platform={args.platform}", f"target={target}", f"-j{args.jobs}"],
           cwd=str(HERE))

    tmpl = HERE / "video_rec.gdextension.disabled"
    active = HERE / "video_rec.gdextension"
    if tmpl.exists() and not active.exists():
        active.write_text(tmpl.read_text())
        print(f"\nActivated {active.name} — reopen the Godot project.")

    print("\nBuilt:")
    for f in sorted((HERE / "bin").glob("*")):
        print("  ", f.name)


if __name__ == "__main__":
    main()
