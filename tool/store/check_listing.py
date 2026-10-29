"""Checks docs/store/listing.md against the stores' length limits.

    python3 tool/store/check_listing.py
"""

import re
import sys
from pathlib import Path

LIMITS = {
    "App name": 30,
    "Subtitle": 30,
    "Short description": 80,
    "Promotional text": 170,
    "Keywords": 100,
    "Description": 4000,
}

text = Path(__file__).resolve().parents[2].joinpath("docs/store/listing.md").read_text()
failed = False
for lang in re.split(r"\n## ", text)[1:]:
    language = lang.splitlines()[0]
    for block in re.split(r"\n### ", lang)[1:]:
        heading, _, body = block.partition("\n")
        body = body.split("\n---")[0].strip()
        field = next((f for f in LIMITS if heading.startswith(f)), None)
        if field is None:
            continue
        n = len(body)
        ok = n <= LIMITS[field]
        failed |= not ok
        print(f"{'ok ' if ok else 'TOO LONG'} {language[:10]:10} {field:18} {n:5} / {LIMITS[field]}")
sys.exit(1 if failed else 0)
