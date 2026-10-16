"""Paste this file into an Azure SRE Agent Python tool's Code tab."""

import json
import re
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone


MAX_BYTES = 1_000_000
MAX_LINES = 20_000
MAX_GROUPS = 10
TIMESTAMP = re.compile(r"\b\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:[.,]\d+)?(?:Z|[+-]\d\d:?\d\d)?")
STATUS = re.compile(r"\b(?:status|statusCode|http_status|HTTP)\s*[=: ]\s*([1-5]\d\d)\b", re.I)
LEVEL = re.compile(r"\b(ERROR|FATAL|CRITICAL|WARN(?:ING)?|INFO|DEBUG)\b", re.I)
ID = re.compile(r"\b(?:correlation[_-]?id|trace[_-]?id|request[_-]?id)\s*[=:]\s*([\w.-]+)", re.I)
PARTY = re.compile(r"\b(?:party|partner|counterparty|system)\s*[=:]\s*([\w.-]+)", re.I)
SECRET = re.compile(
    r"(?i)\b(authorization|api[_-]?key|access[_-]?token|client[_-]?secret|password|"
    r"connection[_-]?string|sig)\s*[=:]\s*"
    r"(?:bearer\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"
)
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b", re.I)
LONG_ID = re.compile(r"\b(?=[a-f0-9-]{16,}\b)[a-f0-9-]+\b", re.I)
NUMBER = re.compile(r"\b\d+\b")
ACCOUNT = re.compile(r"^[a-z0-9]{3,24}$")
CONTAINER = re.compile(r"^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$")


def _redact(value):
    value = SECRET.sub(lambda m: m.group(1) + "=[REDACTED]", str(value))
    return EMAIL.sub("[EMAIL]", value)


def _timestamp(value):
    match = TIMESTAMP.search(str(value))
    if not match:
        return None
    text = match.group().replace(" ", "T").replace(",", ".")
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        result = datetime.fromisoformat(text)
    except ValueError:
        return None
    return (result if result.tzinfo else result.replace(tzinfo=timezone.utc)).astimezone(timezone.utc)


def _field(record, *names):
    for name in names:
        if name in record and record[name] is not None:
            return str(record[name])
    return ""


def _classify(level, status, message):
    if status is not None and status >= 400:
        return "error"
    if level in ("ERROR", "FATAL", "CRITICAL"):
        return "error"
    if level in ("WARN", "WARNING"):
        return "warning"
    if status is not None and 200 <= status < 400:
        return "success"
    if re.search(r"\b(?:succeeded|success|completed)\b", message, re.I):
        return "success"
    return "other"


def _signature(message, status):
    value = _redact(message)
    value = UUID.sub("<id>", value)
    value = LONG_ID.sub("<id>", value)
    value = re.sub(r"\bhttps?://[^\s]+", "<url>", value)
    value = NUMBER.sub("<n>", value)
    value = re.sub(r"\s+", " ", value).strip()[:180]
    return ("HTTP %s " % status if status and status >= 400 else "") + (value or "(empty message)")


def _parse_line(line, line_number):
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        data = None
    record = data if isinstance(data, dict) else {}
    message = _field(record, "message", "msg", "Message", "error", "exception") or line
    raw_status = _field(record, "statusCode", "status_code", "httpStatus", "http_status")
    status_match = STATUS.search(message if not raw_status else "status=" + raw_status)
    status = int(status_match.group(1)) if status_match else None
    level = _field(record, "level", "severity", "severityLevel").upper()
    if not level:
        level_match = LEVEL.search(line)
        level = level_match.group(1).upper() if level_match else ""
    party = _field(record, "party", "partner", "counterparty", "system")
    party_match = PARTY.search(message) if not party else None
    party = party or (party_match.group(1) if party_match else "")
    correlation = _field(record, "correlationId", "correlation_id", "traceId", "trace_id", "requestId", "request_id")
    id_match = ID.search(message) if not correlation else None
    correlation = correlation or (id_match.group(1) if id_match else "")
    time = _timestamp(_field(record, "timestamp", "time", "TimeGenerated", "date") or line)
    kind = _classify(level, status, message)
    return {
        "line": line_number, "time": time, "kind": kind, "status": status,
        "party": _redact(party)[:100] or "unknown",
        "correlation_id": _redact(correlation)[:100] or None,
        "signature": _signature(message, status),
        "excerpt": _redact(message).strip()[:240],
    }


def _read_blob(account, container, name):
    if not ACCOUNT.fullmatch(account) or not CONTAINER.fullmatch(container):
        raise ValueError("Invalid storage account or container name")
    if not name or name.startswith("/") or len(name) > 1024:
        raise ValueError("Invalid blob name")
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import BlobServiceClient

    service = BlobServiceClient(
        account_url="https://%s.blob.core.windows.net" % account,
        credential=DefaultAzureCredential(exclude_interactive_browser_credential=True),
    )
    client = service.get_blob_client(container=container, blob=name)
    size = client.get_blob_properties().size
    if size > MAX_BYTES:
        raise ValueError("Blob exceeds 1 MB; select a bounded incident slice")
    content = client.download_blob(max_concurrency=1).readall()
    if len(content) > MAX_BYTES:
        raise ValueError("Blob exceeds 1 MB")
    return content.decode("utf-8-sig", errors="strict")


def main(log_text: str = "", storage_account: str = "", container: str = "", blob_name: str = "") -> dict:
    """Analyze UTF-8 newline-delimited JSON or plain-text integration logs.

    Supply log_text alone, or storage_account, container and blob_name for
    read-only managed-identity access to a bounded Azure Blob.
    """
    using_blob = any((storage_account, container, blob_name))
    if using_blob:
        if log_text or not all((storage_account, container, blob_name)):
            raise ValueError("Supply either log_text or all three Blob coordinates, not both")
        log_text = _read_blob(storage_account, container, blob_name)
    if not isinstance(log_text, str) or not log_text.strip():
        raise ValueError("Non-empty log_text or Blob coordinates are required")
    if len(log_text.encode("utf-8")) > MAX_BYTES:
        raise ValueError("Input exceeds 1 MB; select a bounded incident slice")
    lines = log_text.splitlines()
    if len(lines) > MAX_LINES:
        raise ValueError("Input exceeds 20,000 lines")
    records = [_parse_line(line, i) for i, line in enumerate(lines, 1) if line.strip()]
    errors = [r for r in records if r["kind"] == "error"]
    successes = [r for r in records if r["kind"] == "success"]
    times = [r["time"] for r in records if r["time"]]
    latest = max(times) if times else None
    first = min(times) if times else None
    groups = defaultdict(list)
    for record in errors:
        groups[(record["party"], record["signature"])].append(record)
    ranked = sorted(groups.items(), key=lambda item: (-len(item[1]), item[0]))
    findings = []
    for (party, signature), items in ranked[:MAX_GROUPS]:
        dated = sorted((r for r in items if r["time"]), key=lambda r: r["time"])
        same_party_successes = sorted(
            (r for r in successes if r["party"] == party and r["time"]),
            key=lambda r: r["time"], reverse=True
        )
        findings.append({
            "party": party,
            "signature": signature,
            "count": len(items),
            "status_codes": dict(sorted(Counter(r["status"] for r in items if r["status"]).items())),
            "first_seen_utc": dated[0]["time"].isoformat() if dated else None,
            "last_seen_utc": dated[-1]["time"].isoformat() if dated else None,
            "same_party_latest_success": (
                {"line": same_party_successes[0]["line"],
                 "time_utc": same_party_successes[0]["time"].isoformat(),
                 "excerpt": same_party_successes[0]["excerpt"]}
                if same_party_successes else None
            ),
            "recent_examples": [
                {"line": r["line"], "time_utc": r["time"].isoformat() if r["time"] else None,
                 "correlation_id": r["correlation_id"], "excerpt": r["excerpt"]}
                for r in (dated[-3:] if dated else items[-3:])
            ],
        })
    windows = {}
    if latest:
        for label, duration in (("24h", timedelta(hours=24)), ("7d", timedelta(days=7))):
            window_start = latest - duration
            windows[label] = {
                "anchor_utc": latest.isoformat(),
                "errors": sum(1 for r in errors if r["time"] and r["time"] >= window_start),
                "successes": sum(1 for r in successes if r["time"] and r["time"] >= window_start),
            }
    recent_successes = sorted(
        (r for r in successes if r["time"]), key=lambda r: r["time"], reverse=True
    )[:5]
    return {
        "source": "blob" if using_blob else "pasted_text",
        "lines": len(records),
        "counts": dict(Counter(r["kind"] for r in records)),
        "timestamped_lines": len(times),
        "observed_first_utc": first.isoformat() if first else None,
        "observed_last_utc": latest.isoformat() if latest else None,
        "observed_windows": windows,
        "error_groups": findings,
        "omitted_error_groups": max(0, len(ranked) - MAX_GROUPS),
        "recent_successes": [
            {"line": r["line"], "time_utc": r["time"].isoformat(), "party": r["party"],
             "correlation_id": r["correlation_id"], "excerpt": r["excerpt"]}
            for r in recent_successes
        ],
        "limitations": [
            "Counts cover only provided lines, not all production traffic or a complete 24h/7d interval.",
            "Status/level classification and signature grouping are heuristic; review evidence before assigning cause.",
            "Party and correlation are unknown unless present in the supplied logs.",
        ],
    }
