#!/usr/bin/env python3
"""How busy the running Drakar's main thread is, and on what.

Attaches Instruments' Time Profiler to the running app for a while, then prints the main
thread's share of wall time, its heaviest app functions (inclusive) and its heaviest leaf
functions (self). Run the same scenario before and after a change and compare.

    scripts/profile.py [--seconds 30] [--pid PID] [--keep] [--top 40]

The Time Profiler barely slows the app; the SwiftUI template does (it symbolicates a
backtrace on every observation), so its timings are not to be trusted, only its counts.
Profile a Release build made here (`make build-release`): Debug's unoptimised code
inflates the app's own frames, and a notarized build refuses the attach.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections import Counter

APP_BINARIES = ("Drakar", "DrakarKit")


def running_pid():
    out = subprocess.run(["pgrep", "-x", "Drakar"], capture_output=True, text=True).stdout
    pids = out.split()
    if not pids:
        sys.exit("Drakar is not running")
    if len(pids) > 1:
        sys.exit(f"several Drakar processes ({', '.join(pids)}): pass --pid")
    return pids[0]


def record(pid, seconds, trace):
    subprocess.run(
        ["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", pid,
         "--time-limit", f"{seconds}s", "--output", trace],
        check=True, stdout=subprocess.DEVNULL)


def export(trace, xml_path):
    query = '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'
    with open(xml_path, "wb") as out:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", query],
                       check=True, stdout=out)


def samples(xml_path):
    """(thread name, weight in ns, stack leaf first as (function, binary)) per sample."""
    frames, binaries, stacks, threads, weights = {}, {}, {}, {}, {}

    def frame(el):
        if el.get("ref"):
            return frames[el.get("ref")]
        binary = el.find("binary")
        name = ""
        if binary is not None:
            if binary.get("ref"):
                name = binaries.get(binary.get("ref"), "")
            else:
                name = binary.get("name", "")
                binaries[binary.get("id")] = name
        value = (el.get("name", "?"), name)
        frames[el.get("id")] = value
        return value

    for _, el in ET.iterparse(xml_path, events=("end",)):
        if el.tag != "row":
            continue
        thread = el.find("thread")
        if thread.get("ref"):
            tname = threads[thread.get("ref")]
        else:
            tname = thread.get("fmt")
            threads[thread.get("id")] = tname
        weight = el.find("weight")
        if weight.get("ref"):
            w = weights[weight.get("ref")]
        else:
            w = int(weight.text)
            weights[weight.get("id")] = w
        trace = el.find("tagged-backtrace")
        if trace is None:
            trace = el.find("backtrace")
        stack = ()
        if trace is not None:
            if trace.get("ref"):
                stack = stacks[trace.get("ref")]
            else:
                stack = tuple(frame(f) for f in trace.findall("frame"))
                stacks[trace.get("id")] = stack
        yield tname, w, stack
        el.clear()


def is_app(binary):
    return binary.split(".")[0] in APP_BINARIES


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--pid")
    parser.add_argument("--top", type=int, default=40)
    parser.add_argument("--keep", action="store_true", help="keep the .trace and print its path")
    args = parser.parse_args()

    pid = args.pid or running_pid()
    work = tempfile.mkdtemp(prefix="drakar-profile-")
    trace = os.path.join(work, "drakar.trace")
    xml_path = os.path.join(work, "time-profile.xml")
    try:
        print(f"Recording Drakar ({pid}) for {args.seconds} s…", file=sys.stderr)
        record(pid, args.seconds, trace)
        export(trace, xml_path)

        per_thread = Counter()
        inclusive, leaf = Counter(), Counter()
        main_ns = 0
        for thread, w, stack in samples(xml_path):
            per_thread[thread] += w
            if not thread.startswith("Main Thread"):
                continue
            main_ns += w
            if stack:
                function, binary = stack[0]
                leaf[f"{function[:110]}  [{binary}]"] += w
            seen = set()
            for function, binary in stack:
                if is_app(binary) and function not in seen:
                    seen.add(function)
                    inclusive[function] += w

        wall_ns = args.seconds * 1e9
        print(f"main thread busy: {100 * main_ns / wall_ns:.1f}% "
              f"({main_ns / 1e6:.0f} ms of {args.seconds} s)")
        print(f"all threads: {sum(per_thread.values()) / 1e6:.0f} ms CPU")
        print("\nheaviest app functions on the main thread (inclusive):")
        skip = ("main()", "$main()", "entry_point")
        shown = 0
        for function, w in inclusive.most_common():
            if function == "main" or any(s in function for s in skip):
                continue
            print(f"  {w / 1e6:8.0f} ms {100 * w / max(main_ns, 1):5.1f}%  {function[:140]}")
            shown += 1
            if shown >= args.top:
                break
        print("\nheaviest leaves on the main thread (self):")
        for function, w in leaf.most_common(20):
            print(f"  {w / 1e6:8.0f} ms {100 * w / max(main_ns, 1):5.1f}%  {function}")
        if args.keep:
            kept = os.path.join(tempfile.gettempdir(), f"drakar-{pid}-{os.getpid()}.trace")
            shutil.move(trace, kept)
            print(f"\ntrace: {kept}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
