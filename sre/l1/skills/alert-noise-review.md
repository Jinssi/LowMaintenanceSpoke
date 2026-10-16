# Weekly alert noise review (read-only)

Goal: fewer, better tickets. Look at the last 7 days of alerts in `{{SPOKE_RG}}` and `{{HUB_RG}}`.

1. For each alert rule: number of fires, how many were closed with `[L1-CLOSE] noise` or `self-healed`, median time
   to close, and how many were escalated.
2. Flag rules that:
   - fired more than 10 times and were noise more than 70% of the time (threshold too tight or window too short),
   - never fired but had related user impact (missing coverage),
   - were escalated more than 3 times for the same cause (needs a permanent fix, not more triage).
3. For each flagged rule, propose **one concrete IaC change**: file, rule name, current value → proposed value, and why.
   Use `known-noise-and-thresholds` for context.

Output a table: *rule · fires · noise % · escalations · proposal*. Don't change alert rules or alert states.
