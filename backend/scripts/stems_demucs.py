#!/usr/bin/env python3
import argparse
import glob
import json
import os
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--model", default="htdemucs_ft")
    args = parser.parse_args()

    input_path = os.path.abspath(args.input)
    output_root = os.path.abspath(args.output_root)
    os.makedirs(output_root, exist_ok=True)

    cmd = [
        sys.executable,
        "-m",
        "demucs.separate",
        "--two-stems",
        "vocals",
        "-n",
        args.model,
        "--out",
        output_root,
        input_path,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr or proc.stdout or "demucs_failed\n")
        return proc.returncode

    pattern = os.path.join(output_root, "**", "no_vocals.*")
    matches = glob.glob(pattern, recursive=True)
    if not matches:
        sys.stderr.write("no_vocals_not_found\n")
        return 2

    matches.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    instrumental_path = os.path.abspath(matches[0])
    print(json.dumps({"ok": True, "instrumental_path": instrumental_path}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

