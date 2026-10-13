#!/usr/bin/env python3
"""Fail closed before signing while the production security hold has blockers."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
hold_path = root / "SECURITY_HOLD.md"
hold = hold_path.read_text(encoding="utf-8")
required = (
    "Authentication and access control",
    "Encrypted data storage",
    "Secure Google Drive backup and recovery",
    "File I/O and offline behavior",
    "Repository/build integrity",
    "Release validation",
)
blockers = []
for section in required:
    lines = [line for line in hold.splitlines() if section in line]
    if not lines or not any(line.startswith("- [x]") for line in lines):
        blockers.append(section)

if blockers:
    print("PRODUCTION RELEASE BLOCKED: SECURITY_HOLD.md still has unresolved acceptance requirements.")
    for item in blockers:
        print(f"- {item}")
    print("Do not bypass this gate by changing checkboxes without implementing and evidencing the control.")
    sys.exit(1)

print("Production security hold marked complete. This gate is a checklist guard, not independent proof of security.")
