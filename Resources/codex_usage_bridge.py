#!/usr/bin/env python3
"""Read the signed-in ChatGPT account's official Codex rate limits.

The bridge speaks the documented local Codex app-server JSON-RPC protocol.
It never reads or prints auth files, bearer tokens, prompts, or session logs.
Only the account label, plan name, quota windows, and reset timestamps are
returned to TDZStatus.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import time
from pathlib import Path


def codex_binary() -> str | None:
    candidates = [
        shutil.which("codex"),
        str(Path.home() / ".npm-global/bin/codex"),
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/MacOS/codex",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def send(process: subprocess.Popen[bytes], payload: dict) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
    process.stdin.flush()


class BufferedLineReader:
    """Read newline-delimited app-server messages without mixing select and TextIO buffering."""

    def __init__(self, stream) -> None:
        self.stream = stream
        self.fd = stream.fileno()
        self.buffer = bytearray()

    def read_line(self, deadline: float) -> bytes:
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                line = bytes(self.buffer[:newline])
                del self.buffer[: newline + 1]
                return line
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Codex did not return usage limits in time.")
            ready, _, _ = select.select([self.fd], [], [], min(remaining, 0.5))
            if not ready:
                continue
            chunk = os.read(self.fd, 65536)
            if not chunk:
                raise RuntimeError("Codex app-server closed its output before returning usage data.")
            self.buffer.extend(chunk)


def response_for(
    process: subprocess.Popen[bytes], reader: BufferedLineReader, request_id: int, timeout: float = 12
) -> dict:
    assert process.stdout is not None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            line = reader.read_line(deadline)
        except TimeoutError:
            if process.poll() is not None:
                raise RuntimeError("Codex app-server stopped before returning usage data.")
            raise
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(message, dict) and message.get("id") == request_id:
            if "error" in message:
                error = message.get("error")
                if isinstance(error, dict):
                    raise RuntimeError(str(error.get("message") or "Codex app-server request failed."))
                raise RuntimeError("Codex app-server request failed.")
            result = message.get("result")
            return result if isinstance(result, dict) else {}
    raise TimeoutError("Codex did not return usage limits in time.")


def numeric(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def main() -> int:
    binary = codex_binary()
    if binary is None:
        print(json.dumps({"error": "Codex CLI was not found."}))
        return 0

    environment = os.environ.copy()
    environment["CODEX_HOME"] = os.path.expanduser(
        environment.get("CODEX_HOME") or "~/.codex"
    )
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            [binary, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
            env=environment,
        )
        assert process.stdout is not None
        reader = BufferedLineReader(process.stdout)
        send(process, {
            "method": "initialize",
            "id": 0,
            "params": {
                "clientInfo": {
                    "name": "tdzstatus",
                    "title": "TDZStatus",
                    "version": "1.0",
                }
            },
        })
        response_for(process, reader, 0)
        send(process, {"method": "initialized"})
        send(process, {
            "method": "account/read",
            "id": 1,
            "params": {"refreshToken": False},
        })
        account_result = response_for(process, reader, 1)
        account = account_result.get("account")
        if not isinstance(account, dict) or account.get("type") != "chatgpt":
            print(json.dumps({"error": "A ChatGPT account is not connected to this Codex profile."}))
            return 0

        send(process, {"method": "account/rateLimits/read", "id": 2})
        result = response_for(process, reader, 2)
        by_id = result.get("rateLimitsByLimitId")
        if not isinstance(by_id, dict):
            single = result.get("rateLimits")
            by_id = {single.get("limitId", "codex"): single} if isinstance(single, dict) else {}

        windows = []
        for key, bucket in by_id.items():
            if not isinstance(bucket, dict):
                continue
            for period in ("primary", "secondary"):
                window = bucket.get(period)
                if not isinstance(window, dict):
                    continue
                used = numeric(window.get("usedPercent"))
                if used is None:
                    continue
                resets = numeric(window.get("resetsAt"))
                duration = numeric(window.get("windowDurationMins"))
                title = bucket.get("limitName") or bucket.get("limitId") or key
                if period == "secondary" and duration:
                    title = f"{title} · longer window"
                windows.append({
                    "id": f"{key}:{period}",
                    "title": str(title),
                    "usedPercentage": max(0, min(100, used)),
                    "windowDurationMinutes": int(duration) if duration is not None else None,
                    "resetsAt": resets,
                })

        if not windows:
            print(json.dumps({"error": "Codex returned no rate-limit windows for this account."}))
            return 0

        print(json.dumps({
            "accountName": account.get("email") if isinstance(account.get("email"), str) else None,
            "planName": account.get("planType") if isinstance(account.get("planType"), str) else None,
            "windows": windows,
            "fetchedAt": time.time(),
        }, separators=(",", ":")))
        return 0
    except (OSError, RuntimeError, TimeoutError) as error:
        print(json.dumps({"error": str(error)}))
        return 0
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
