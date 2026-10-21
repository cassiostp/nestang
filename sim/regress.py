#!/usr/bin/env python3
"""Recipe-aware simulation launcher. The adjacent TSV is the bench catalog."""
import argparse
import concurrent.futures
import csv
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import threading
import time

SIM = Path(__file__).resolve().parent
ROOT = SIM.parent
CATALOG = list(csv.DictReader((SIM / "regress.tsv").open(), delimiter="\t"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tier", nargs="?", choices=("quick", "full"), default="quick")
    parser.add_argument("variant", nargs="?", choices=("standard", "hz120", "both"), default="both")
    parser.add_argument("--only", help="comma-separated bench names from --list")
    parser.add_argument("--list", action="store_true", help="show the complete catalog without running")
    args = parser.parse_args()
    names = set(args.only.split(",")) if args.only else {b["bench"] for b in CATALOG}
    unknown = names - {b["bench"] for b in CATALOG}
    if unknown:
        parser.error("unknown benches: " + ", ".join(sorted(unknown)))
    if args.list:
        print("bench\ttier\tvariants\tcontainer (host orchestrates host rows)\ttypical seconds/leg\tcoverage notes")
        for b in CATALOG:
            if b["bench"] in names:
                print("\t".join([b["bench"], b["tier"], b["variants"], b["container"], b["seconds"], b.get("notes", "")]))
        return 0
    state = SIM / ".regress"
    state.mkdir(exist_ok=True)
    # run.sh recipes write fixed build paths; concurrent invocations must not race.
    lock = (state / "lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("another regression invocation is using this checkout")
    out = state / (time.strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid()))
    out.mkdir()
    env = os.environ.copy()
    env.setdefault("VERILATOR_THREADS", "1")
    env.setdefault("SIM_PREFIX", "sim" + str(os.getpid()))
    env.setdefault("DOCKER_RUN", "simrun" if shutil_which("simrun") else "docker run --rm")
    romroot = Path(env.get("TANGCORE_ROMS", str(Path.home() / "tangcore-test-bundle/test roms"))).expanduser()
    locks = {}
    tasks = []
    for b in CATALOG:
        if b["bench"] not in names or (args.tier == "quick" and b["tier"] == "full"):
            continue
        variants = ["shared"] if b["variants"] == "shared" else (["standard", "hz120"] if args.variant == "both" else [args.variant])
        for variant in variants:
            # A common group also serializes benches that write the same directory/header.
            group = b["group"] or b["directory"]
            locks.setdefault(group, threading.Lock())
            tasks.append((b, variant, locks[group]))
    if not tasks:
        parser.error("no benches selected in this tier")
    suite_start = time.monotonic()
    print("bench\tvariant\tresult\tseconds\tlog path / reason", flush=True)
    results = []
    # GBA scripts materialize one common/variant.vh for every video recipe.
    jobs = env.get("REGRESS_JOBS", "2")
    if jobs not in ("1", "2"):
        parser.error("REGRESS_JOBS must be 1 or 2")
    workers = int(jobs)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        queued, active, busy = list(tasks), {}, set()
        while queued or active:
            # A waiting variant must not occupy a worker needed by another bench.
            for task in list(queued):
                if len(active) == workers:
                    break
                b, variant, guard = task
                if guard in busy:
                    continue
                future = pool.submit(run, b, variant, guard, env, romroot, out)
                active[future] = guard
                busy.add(guard)
                queued.remove(task)
            done, _ = concurrent.futures.wait(active, return_when=concurrent.futures.FIRST_COMPLETED)
            for future in done:
                busy.remove(active.pop(future))
                result = future.result()
                results.append(result)
                print("\t".join(map(str, result)), flush=True)
    results.sort(key=lambda r: (r[0], r[1]))
    with (out / "results.tsv").open("w") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(("bench", "variant", "result", "seconds", "log/reason"))
        writer.writerows(results)
    counts = {status: sum(r[2] == status for r in results) for status in ("PASS", "FAIL", "SKIP")}
    elapsed = round(time.monotonic() - suite_start, 1)
    metadata = dict(tier=args.tier, variant=args.variant, only=args.only, wall_seconds=elapsed, counts=counts)
    (out / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print("Summary: " + ", ".join(f"{v} {k}" for k, v in counts.items()) + f"; wall: {elapsed}s; table: {out / 'results.tsv'}", flush=True)
    return int(counts["FAIL"] > 0)


def shutil_which(name):
    import shutil
    return shutil.which(name)


def run(b, variant, guard, base_env, romroot, out):
    logfile = out / (b["bench"] + "-" + variant + ".log")
    if variant != "shared" and variant not in b["variants"].split(","):
        reason = "not applicable: recipe supports " + b["variants"]
        logfile.write_text(reason + "\n")
        return b["bench"], variant, "SKIP", 0, f"{logfile} ({reason})"
    rom = None
    if b["rom"]:
        rom = next(iter(sorted(romroot.rglob(b["rom"]))), None) if romroot.is_dir() else None
        if rom is None:
            reason = f"ROM not found: {b['rom']} under {romroot} (set TANGCORE_ROMS)"
            logfile.write_text(reason + "\n")
            return b["bench"], variant, "SKIP", 0, f"{logfile} ({reason})"
    with guard:
        start = time.monotonic()
        env = base_env.copy()
        env["SIM_PREFIX"] += "_" + ROOT.name + "_" + b["bench"] + "_" + variant
        env["CONTAINER_PREFIX"] = env["SIM_PREFIX"]
        directory = SIM / b["directory"]
        output = out / (b["bench"] + "-" + variant + "-output")
        values = {"variant": variant, "rom": str(rom or ""), "output": str(output), "root": str(ROOT)}
        values = {key: shlex.quote(value) for key, value in values.items()}
        def expand(command):
            for key, value in values.items():
                command = command.replace("{" + key + "}", value)
            return command
        def call(command, container=False):
            if container:
                image = {"iv": "tangcore-iv:1", "vlt": "verilator/verilator:latest", "ghdl": env.get("GHDL_IMG", "cx4_ghdl:1")}[b["runner"]]
                # Mount at the same absolute path: generated source paths remain host-valid.
                cmd = shlex.split(env["DOCKER_RUN"]) + ([] if "simrun" in env["DOCKER_RUN"] else ["-e", "CCACHE_DISABLE=1"]) + ["--name", env["SIM_PREFIX"] + "_run", "--user", f"{os.getuid()}:{os.getgid()}", "-v", f"{ROOT}:{ROOT}", *(["-v", f"{romroot}:{romroot}:ro"] if romroot.is_dir() else []), "-w", str(directory), "-e", "VERILATOR_THREADS=" + env["VERILATOR_THREADS"], "--entrypoint", "sh", image, "-ec", command]
            else:
                cmd = ["sh", "-ec", command]
            log.write(("$ " + shlex.join(cmd) + "\n").encode())
            log.flush()
            subprocess.run(cmd, cwd=directory, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        status = "PASS"
        with logfile.open("wb") as log:
            try:
                # Icarus image has no Python/Git; generate historical goldens on the host.
                if (directory / "prep.sh").is_file() and b["runner"] == "iv":
                    call("sh prep.sh")
                if b["bench"] == "tmds":
                    script = (directory / "run.sh").read_text()
                    baseline = env.get("BASE") or re.search(r"BASE=\$\{BASE:-([^}]+)\}", script).group(1)
                    rtl = "src/hdmi2" if (ROOT / "src/hdmi2").is_dir() else "src/hdmi"
                    call(f"mkdir -p build; git show {shlex.quote(baseline + ':' + rtl + '/tmds_channel.sv')} | sed 's/^module tmds_channel$/module tmds_channel_old/' > build/tmds_channel_old.sv; grep -q '^module tmds_channel_old$' build/tmds_channel_old.sv")
                if b["pre"]:
                    call(expand(b["pre"]))
                call(expand(b["command"]), b["runner"] in ("iv", "vlt", "ghdl"))
                if b["post"]:
                    call(expand(b["post"]))
            except (subprocess.CalledProcessError, OSError) as error:
                log.write((str(error) + "\n").encode())
                status = "FAIL"
        return b["bench"], variant, status, round(time.monotonic() - start, 1), str(logfile)


if __name__ == "__main__":
    sys.exit(main())
