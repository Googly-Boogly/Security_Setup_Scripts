"""Structured audit events for agent tool calls (Python stdlib only).

Inside a container started by agent_runner.sh this module is importable as
``agent_audit`` and appends JSON lines to $AGENT_AUDIT_LOG, which lives on
the host under ~/.local/state/ai-agent-runner/sessions/<session>/.

    from agent_audit import audited, log_event

    with audited("http", "GET", target="https://api.example.com/items"):
        response = client.get(...)

    log_event("shell", "exec", target="pytest -q", result="ok", exit_code=0)

Shell agents can use the CLI:
    python3 /opt/agent-tools/agent_audit.py --tool shell --action exec \
        --target "ls -la" --result ok --exit-code 0

Trust note: these events are written by the agent itself, so they are claims,
not evidence. A compromised agent can lie or stop logging. The runner's own
log (~/.local/state/ai-agent-runner/audit.jsonl) is written outside the
container and is the trusted record of what was started, with which
limits, and how it ended.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any, Iterator

_SENSITIVE_KEY = re.compile(
    r"(pass(word|wd)?|secret|token|api[_-]?key|auth|credential|cookie|session[_-]?key|private[_-]?key)",
    re.IGNORECASE,
)
_TOKEN_PATTERNS = [
    re.compile(p)
    for p in (
        r"sk-[A-Za-z0-9_-]{16,}",
        r"(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}",
        r"AKIA[0-9A-Z]{16}",
        r"xox[baprs]-[A-Za-z0-9-]{10,}",
        r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",  # JWT
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    )
]
_URL_CREDENTIALS = re.compile(r"(://[^:/@\s]+:)[^@\s]+@")
_REDACTED = "[REDACTED]"
_MAX_FIELD = 2000


def redact(value: Any, key: str = "") -> Any:
    """Mask secrets in nested data. Keys that look sensitive are masked whole."""
    if key and _SENSITIVE_KEY.search(key):
        return _REDACTED
    if isinstance(value, dict):
        return {k: redact(v, str(k)) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [redact(v) for v in value]
    if isinstance(value, str):
        for pattern in _TOKEN_PATTERNS:
            value = pattern.sub(_REDACTED, value)
        value = _URL_CREDENTIALS.sub(r"\1" + _REDACTED + "@", value)
        return value if len(value) <= _MAX_FIELD else value[:_MAX_FIELD] + "...[truncated]"
    return value


def log_event(
    tool: str,
    action: str,
    target: str = "",
    result: str = "ok",
    exit_code: int | None = None,
    duration: float | None = None,
    **extra: Any,
) -> None:
    """Append one audit event. Never raises: logging must not break the agent."""
    event = {
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "agent_id": os.environ.get("AGENT_ID", ""),
        "session_id": os.environ.get("AGENT_SESSION_ID", ""),
        "tool": tool,
        "action": action,
        "target": target,
        "result": result,
        "exit_code": exit_code,
        "duration_s": None if duration is None else round(duration, 3),
    }
    if extra:
        event["extra"] = extra
    line = json.dumps(redact(event), separators=(",", ":"), default=str)
    path = os.environ.get("AGENT_AUDIT_LOG")
    try:
        if path:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        else:
            print(line, file=sys.stderr)
    except OSError:
        print(line, file=sys.stderr)


@contextmanager
def audited(tool: str, action: str, target: str = "", **extra: Any) -> Iterator[None]:
    """Log an event with duration and ok/error result around a block."""
    start = time.monotonic()
    try:
        yield
    except BaseException as exc:
        log_event(tool, action, target, result="error", duration=time.monotonic() - start,
                  error=type(exc).__name__, **extra)
        raise
    log_event(tool, action, target, result="ok", duration=time.monotonic() - start, **extra)


def _main() -> int:
    parser = argparse.ArgumentParser(description="Append an agent audit event")
    parser.add_argument("--tool", required=True)
    parser.add_argument("--action", required=True)
    parser.add_argument("--target", default="")
    parser.add_argument("--result", default="ok")
    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--duration", type=float)
    args = parser.parse_args()
    log_event(args.tool, args.action, args.target, args.result, args.exit_code, args.duration)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
