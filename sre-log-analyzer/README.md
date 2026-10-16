# Azure SRE Agent integration log investigator

Standalone pilot package (not wired into the surrounding application). It provides a custom skill and a read-only Python tool; the tool groups raw failures, extracts correlation evidence, and compares observed successes. The SRE Agent interprets the tool output and proposes checks, rather than claiming a deterministic root cause.

## Set up in your SRE Agent

1. In [sre.azure.com](https://sre.azure.com), select an existing Azure SRE Agent. You need Builder permissions. In **Builder > Agent Canvas > Create > Tool > Python tool**, name it `analyze_integration_logs`, describe it as "Analyze bounded raw Azure integration logs or read-only Blob logs into evidence-backed failure groups and recent successes", and paste the entire contents of `log_analyzer_tool.py` into **Code**. Do not replace it with AI-generated code.
2. For Blob access, select the **Storage** scope in the tool's **Identity** tab and give the agent managed identity **Storage Blob Data Reader** on the specific container/account. Confirm the Python tool runtime has `azure-identity` and `azure-storage-blob`; install/enable them there if missing. Use a private blob; do not use account keys or public URLs. For pasted logs, Blob identity/dependencies are unnecessary.
3. In **Builder > Agent Canvas > Create skill**, name it `integration-log-investigator` and paste `SKILL.md`. Choose the `analyze_integration_logs` tool in the skill's **Tools** section (or attach it directly to a dedicated subagent for more consistent selection).
4. Test the Python tool in its **Test playground** with `log_text` from `examples/sample.log` (leave Blob inputs empty). Check the failure groups and redaction. Then test the skill in a new chat: "Investigate the integration failures in these logs; show observed counts, evidence lines, plausible causes, and a safe next check." For Blob tests, leave `log_text` empty and fill all three Blob coordinates.
5. Optionally create a subagent under **Builder > Agent Canvas > Create subagent**, give it the name `integration-log-triage`, use the instructions in `SKILL.md`, enable only this skill and the Python tool, and test it in the playground. This package does not create an Azure resource or change your existing agent automatically.

Example Blob call (values are placeholders, not secrets):

```json
{"log_text":"","storage_account":"mystorageaccount","container":"integration-logs","blob_name":"incidents/2026-10-02/orders.log"}
```

## Local smoke test

Python 3.9+ and the standard library suffice for pasted logs:

```powershell
# Run from the repository root.
Set-Location .\sre-log-analyzer
python -m unittest discover -s tests -v
```

The tool accepts at most 1 MB / 20,000 lines. It does not stream whole containers or traverse blob names; select an incident slice. A line is treated as one event, so multiline stack traces should be normalized first. JSON fields supported include `timestamp`, `level`, `message`, `statusCode`, `party`/`partner`, and `correlationId`/`traceId`. Plain text supports ISO timestamps, severity, `status=...`, `party=...`, and `correlation_id=...`. No timestamps means no time-window or recent-success reporting. Anonymous output has no raw log dump; snippets still need review for organization-specific PII before wider sharing.

For logs already in Log Analytics or Application Insights, use the SRE Agent's built-in Azure observability/KQL instead of exporting the workspace to Blob. Configure the optional connector for frequently used workspaces. The 24h/7d values from this tool are **observed slice counts**, not authoritative totals. Grant only the resource scope needed, use read-only operation, and keep production changes behind approvals.

References: [Create SRE Agent skill](https://learn.microsoft.com/en-us/azure/sre-agent/create-skill), [Create Python tool](https://learn.microsoft.com/en-us/azure/sre-agent/create-python-tool), [Python tool identity](https://learn.microsoft.com/en-us/azure/sre-agent/python-code-execution), [Log Analytics/App Insights](https://learn.microsoft.com/en-us/azure/sre-agent/log-analytics-app-insights).
