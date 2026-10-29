#!/usr/bin/env python3
"""Write 05-lapwing-first-up-movement.json: Lapwing's `#TPH-` movement chords with the
{:firstup} marker, so each one is sent the moment the first key comes up. Hold `#TPH` and tap
`R` again and again to keep moving left; tap `P` instead to go up.

    python3 make-first-up.py

Run it again after `keymux steno theory lapwing` downloads a newer Lapwing. Only chords that do
nothing but move the caret are marked. Standard library only.
"""

import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
COMMANDS = os.path.join(HERE, "..", "lapwing", "lapwing-commands.json")
OUT = os.path.join(HERE, "05-lapwing-first-up-movement.json")

KEY = r"(?:Left|Right|Up|Down|Home|End|Page_Up|Page_Down)"
MOVE = re.compile(r"^(?:\{#(?:(?:Shift|Control|Alt|Super)_[LR]\()*" + KEY + r"\)*\}(?:\{\^\})?)+$")

with open(COMMANDS, encoding="utf-8") as f:
    commands = json.load(f)

marked = {
    stroke: "{:firstup}" + text
    for stroke, text in commands.items()
    if stroke.startswith("#TPH") and MOVE.match(text)
}
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(marked, f, indent=1, ensure_ascii=False)
    f.write("\n")
print(f"{len(marked)} movement chords marked, written to {os.path.basename(OUT)}")
