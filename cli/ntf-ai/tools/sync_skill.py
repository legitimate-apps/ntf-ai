#!/usr/bin/env python3
"""Sync the skill and AGENTS snippet into the standalone CLI."""
import os, re, sys
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
skill = open(os.path.join(here, "skill", "ntf-ai", "SKILL.md"), encoding="utf-8").read()
if "'''" in skill:
    sys.exit("SKILL.md must not contain three single quotes")
path = os.path.join(here, "ntf_ai.py")
src = open(path, encoding="utf-8").read()
new, n = re.subn(r"(# BEGIN SKILL\n)SKILL_MD = r'''.*?'''\n(# END SKILL)",
                 lambda m: m.group(1) + "SKILL_MD = r'''" + skill + "'''\n" + m.group(2), src, flags=re.S)
if n != 1:
    sys.exit(f"expected one skill block, found {n}")
snippet = open(os.path.join(here, "AGENTS-snippet.md"), encoding="utf-8").read()
new, count = re.subn(r"^AGENTS_SNIPPET = .*?$", lambda m: "AGENTS_SNIPPET = " + repr(snippet), new, flags=re.M)
if count != 1:
    sys.exit(f"expected one snippet block, found {count}")
open(path, "w", encoding="utf-8").write(new)
print("synced" if new != src else "already in sync")
