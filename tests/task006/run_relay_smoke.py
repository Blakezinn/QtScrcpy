# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
# Licensed under the Apache License, Version 2.0 (the "License").
# You may obtain a copy of the License at https://www.apache.org/licenses/LICENSE-2.0
# Distributed on an "AS IS" basis, without warranties or conditions.
"""Independent relay decode smoke A+B for the TASK-006 Core changes.

Uses synthetic credentials and separate local ports, never the real token.
The test fixture and protocol agent are reused unmodified from TASK-004.
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time


CLIENT = Path(__file__).resolve().parents[2]
META = CLIENT.parent.parent
RELAY = META / "relay" / "qtscrcpy-relay.exe"
NETMOCK = META / "repos" / "QtScrcpyAgent" / "tests" / "netmock" / "netmock.py"
FIXTURE = NETMOCK.parent / "data" / "test.h264"
DEPLOY = CLIENT / "out" / "deploy"
SMOKE = DEPLOY / "transport-smoke.exe"
LOG_DIR = CLIENT / "out" / "task006-smoke"
DEVICE = "task006-synthetic"
TOKEN = "synthetic-local-task006"


def free_port():
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        return server.getsockname()[1]


def wait_tcp(port, seconds=8):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("relay did not accept control connections")


def stop(proc):
    if proc is None:
        return
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)


def run_case(case):
    ctl = free_port()
    data = free_port()
    while data == ctl:
        data = free_port()
    credential_file = LOG_DIR / "synthetic-tokens.json"
    credential_file.write_text(json.dumps({DEVICE: TOKEN}), encoding="utf-8")
    relay_out = (LOG_DIR / f"relay-{case}.out").open("w", encoding="utf-8")
    agent_out = (LOG_DIR / f"agent-{case}.out").open("w", encoding="utf-8")
    relay = agent = None
    try:
        relay = subprocess.Popen(
            [str(RELAY), "--ctl", str(ctl), "--data", str(data),
             "--tokens", str(credential_file)],
            cwd=str(META / "relay"), stdout=relay_out, stderr=subprocess.STDOUT,
        )
        wait_tcp(ctl)
        agent = subprocess.Popen(
            [sys.executable, str(NETMOCK), "--host", "127.0.0.1",
             "--ctl-port", str(ctl), "--data-port", str(data),
             "--device-id", DEVICE, "--token", TOKEN, "--video", str(FIXTURE)],
            stdout=agent_out, stderr=subprocess.STDOUT,
        )
        # Start the client after the agent has registered; the test is about
        # actual relay video decoding rather than registration race timing.
        until = time.monotonic() + 8
        while time.monotonic() < until:
            agent_out.flush()
            if "AGENT_REGISTERED" in (LOG_DIR / f"agent-{case}.out").read_text(
                encoding="utf-8", errors="replace"
            ):
                break
            if agent.poll() is not None:
                raise RuntimeError("synthetic agent exited before registration")
            time.sleep(0.1)
        else:
            raise RuntimeError("synthetic agent registration timed out")

        with (LOG_DIR / f"client-{case}.out").open("w", encoding="utf-8") as report:
            code = subprocess.run(
                [str(SMOKE), "--relay", str(DEPLOY), "127.0.0.1",
                 str(ctl), str(data), DEVICE, TOKEN],
                cwd=str(DEPLOY), stdout=report, stderr=subprocess.STDOUT,
                timeout=20, check=False,
            ).returncode
        if code != 0:
            raise RuntimeError(f"transport-smoke exit={code}")
        print(f"PASS {case}: relay + synthetic agent + decoded frames, exit=0", flush=True)
    finally:
        stop(agent)
        stop(relay)
        agent_out.close()
        relay_out.close()
        credential_file.unlink(missing_ok=True)


def main():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    if not all(p.is_file() for p in (RELAY, NETMOCK, FIXTURE, SMOKE)):
        raise RuntimeError("relay, synthetic agent, H264 fixture or smoke binary missing")
    run_case("A")
    run_case("B")
    print("PASS A+B", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as err:
        print("RELAY_SMOKE_FAILED: " + str(err), file=sys.stderr)
        sys.exit(1)
