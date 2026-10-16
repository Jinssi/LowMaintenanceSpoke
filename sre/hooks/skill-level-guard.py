#!/usr/bin/env python3
"""PreToolUse guard for Azure SRE Agent custom agents.

The configure script replaces __POLICY__ with one of:
  l1-triage       read anything, change Azure Monitor alert state only
  l2-commander    read anything, change Azure Monitor alert state only (remediation is handed off)
  l2-remediator   alert state + Container Apps restart / revision (de)activation / traffic / scale
  read-only       no writes at all

Skill level is enforced twice: by Azure RBAC on the agent identity and by this hook.
"""
import json
import re
import sys

POLICY = "__POLICY__"

ALERT_STATE = re.compile(
    r"^az\s+rest\b(?=.*--method\s+post)(?=.*/providers/microsoft\.alertsmanagement/alerts/[^/\s\"']+/changestate)",
    re.IGNORECASE,
)
ACA_REVISION = re.compile(r"^az\s+containerapp\s+revision\s+(restart|activate|deactivate)\b", re.IGNORECASE)
ACA_TRAFFIC = re.compile(r"^az\s+containerapp\s+ingress\s+traffic\s+set\b", re.IGNORECASE)
ACA_UPDATE = re.compile(r"^az\s+containerapp\s+update\b", re.IGNORECASE)
ACA_UPDATE_FLAGS = {
    "--name", "-n", "--resource-group", "-g", "--subscription", "--min-replicas", "--max-replicas",
    "--cpu", "--memory", "--output", "-o", "--only-show-errors", "--query",
}
ALWAYS_DENY = re.compile(
    r"\b(delete|purge|remove)\b|\baz\s+(network|role|keyvault|lock|policy|group|ad|identity|cognitiveservices|acr|resource)\b"
    r"|--set-env-vars|--replace-env-vars|--remove-env-vars|--image\b|--secrets?\b|--registry-",
    re.IGNORECASE,
)
READ_TOOL = re.compile(
    r"^(RunAzCliReadCommands|Query\w*|Search\w*|Read\w*|read_skill_file|List\w*|Get\w*|FileSearch|GrepSearch"
    r"|system-mcp-monitor_\w*(query|list|get)\w*)$",
    re.IGNORECASE,
)
ALERT_TOOL = re.compile(r"^(?=.*(alert|incident))(?=.*(ack|close|resolve|state|comment|note)).*$", re.IGNORECASE)
WRITE_HINT = re.compile(
    r"write|delete|remove|restart|scale|update|create|patch|put|deploy|execute|bash|shell|command",
    re.IGNORECASE,
)

ALLOWED_WRITES = {
    "l1-triage": [ALERT_STATE],
    "l2-commander": [ALERT_STATE],
    "l2-remediator": [ALERT_STATE, ACA_REVISION, ACA_TRAFFIC, ACA_UPDATE],
    "read-only": [],
}


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


def az_commands(tool_input):
    commands = []
    for text in strings(tool_input):
        for part in re.split(r"\n|&&|;|\|\|", text):
            part = part.strip()
            if part.lower().startswith("az "):
                commands.append(part)
    return commands


def update_flags_ok(command):
    flags = re.findall(r"(?:^|\s)(--?[a-zA-Z][\w-]*)", command)
    return all(f.lower() in ACA_UPDATE_FLAGS for f in flags)


def command_allowed(command):
    if ALWAYS_DENY.search(command) and not ALERT_STATE.search(command):
        return False, "command touches a protected area (delete, network, RBAC, Key Vault, image, env vars or secrets)"
    for rule in ALLOWED_WRITES.get(POLICY, []):
        if rule.search(command):
            if rule is ACA_UPDATE and not update_flags_ok(command):
                return False, "only --min-replicas/--max-replicas/--cpu/--memory may be changed with 'az containerapp update'"
            return True, ""
    return False, f"'{POLICY}' is not allowed to run this write command"


def decide(context):
    tool = str(context.get("tool_name") or "")
    tool_input = context.get("tool_input") or {}
    if not tool:
        return False, "hook input could not be parsed (fail closed)"

    if re.search(r"write", tool, re.IGNORECASE) and re.search(r"azcli|cli|az", tool, re.IGNORECASE):
        commands = az_commands(tool_input)
        if not commands:
            return False, "write command could not be parsed for policy evaluation"
        for command in commands:
            ok, reason = command_allowed(command)
            if not ok:
                return False, f"{reason}: {command[:200]}"
        return True, ""

    if READ_TOOL.match(tool):
        return True, ""
    if ALERT_TOOL.search(tool):
        return (POLICY != "read-only"), "read-only agents cannot change alert state"
    if WRITE_HINT.search(tool):
        return False, f"tool '{tool}' can change resources and is not permitted for '{POLICY}'"
    return True, ""


def main():
    try:
        context = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeError):
        context = {}
    ok, reason = decide(context if isinstance(context, dict) else {})
    if ok:
        print(json.dumps({"ok": True, "decision": "allow"}))
        return
    reason = f"Skill-level guard ({POLICY}): {reason}. Escalate or recommend the change instead."
    print(json.dumps({
        "ok": False,
        "decision": "block",
        "reason": reason,
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        },
    }))


if __name__ == "__main__":
    main()
