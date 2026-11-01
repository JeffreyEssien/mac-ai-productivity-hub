#!/usr/bin/env python3
"""Read-only macOS RAM/CPU/swap + data-volume diagnostics; stdlib only."""
import subprocess
import sys


def cmd(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=12, check=False)
        if result.returncode != 0:
            return result.stderr.strip() or f"Command returned {result.returncode}"
        return result.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return str(exc)


def main():
    if sys.platform != "darwin":
        print("This diagnostic requires macOS.")
        return
    try:
        total = int(cmd("sysctl", "-n", "hw.memsize"))
        print(f"Physical RAM: {total / (1024 ** 3):.1f} GiB")
    except ValueError:
        print("Physical RAM unavailable")
    print("\nSwap usage:\n" + cmd("sysctl", "vm.swapusage"))
    print("\nDisk space (shared APFS data volume):\n" + cmd("df", "-h", "/System/Volumes/Data"))
    print("\nProcesses by memory (RSS in KiB):\n" + cmd("ps", "-axo", "pid,rss,%cpu,comm", "-m"))


if __name__ == "__main__":
    main()
