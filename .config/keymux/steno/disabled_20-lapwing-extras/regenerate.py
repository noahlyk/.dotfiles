#!/usr/bin/env python3
"""Make a .json dictionary from each Python dictionary (.py) in this folder.

    python3 regenerate.py            # every .py here
    python3 regenerate.py NAME.py    # just that one

A Python dictionary answers "what does this stroke type?", so this asks each one about every
possible stroke and writes the answers beside it. keymux reads the .json files (and reloads
them as soon as they change), and never runs the .py ones. Standard library only, and about 20
seconds each. Only dictionaries of single strokes can be listed this way.
"""

import importlib.util
import json
import os
import sys
import warnings

sys.dont_write_bytecode = True
# Emily's file writes "\{" in a plain string, which Python means literally but now warns about
warnings.simplefilter("ignore", SyntaxWarning)
HERE = os.path.dirname(os.path.abspath(__file__))

# Stroke keys in Plover's order, number key last: bit 0 is S-, bit 22 is the number key.
KEYS = "STKPWHRAO*EUFRPBLGTSDZ"
LEFT_END, RIGHT_START, NUMBER_BIT = 7, 12, 22
# The keys that write a digit when the number key is down
DIGITS = {0: "1", 1: "2", 3: "3", 5: "4", 7: "5", 8: "0", 12: "6", 14: "7", 16: "8", 18: "9"}


def section(first, count):
    """For every combination of `count` keys from key `first`: the letters, the digits, and
    whether any of the keys carries a digit."""
    plain, digits, has_digit = [], [], []
    for mask in range(1 << count):
        letters, numbers, flag = "", "", False
        for i in range(count):
            if mask >> i & 1:
                key = first + i
                letters += KEYS[key]
                numbers += DIGITS.get(key, KEYS[key])
                flag = flag or key in DIGITS
        plain.append(letters)
        digits.append(numbers)
        has_digit.append(flag)
    return plain, digits, has_digit


LEFT = section(0, LEFT_END)
MIDDLE = section(LEFT_END, RIGHT_START - LEFT_END)
RIGHT = section(RIGHT_START, 10)


def write(bits):
    """A stroke as Plover writes it: digits when the number key is down with a key that has one,
    and a hyphen between the hands when no vowel or star does it."""
    left = bits & 0x7F
    middle = bits >> LEFT_END & 0x1F
    right = bits >> RIGHT_START & 0x3FF
    number = bits >> NUMBER_BIT & 1
    digits = number and (LEFT[2][left] or MIDDLE[2][middle] or RIGHT[2][right])
    hyphen = "-" if right and not middle else ""
    if digits:
        return LEFT[1][left] + hyphen + MIDDLE[1][middle] + RIGHT[1][right]
    return ("#" if number else "") + LEFT[0][left] + hyphen + MIDDLE[0][middle] + RIGHT[0][right]


def convert(source):
    output = os.path.splitext(source)[0] + ".json"
    spec = importlib.util.spec_from_file_location("programmatic", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    longest = getattr(module, "LONGEST_KEY", None)
    if longest != 1:
        print(f"  skipped: outlines of up to {longest} strokes can't be listed one stroke at a time")
        return False
    entries = {}
    for bits in range(1, 1 << 23):
        steno = write(bits)
        try:
            value = module.lookup((steno,))
        except Exception:  # a stroke it has nothing for
            continue
        if value:
            entries[steno] = value
    with open(output + ".part", "w", encoding="utf-8") as fp:
        json.dump(entries, fp, ensure_ascii=False, indent=0, separators=(",", ": "))
        fp.write("\n")
    os.replace(output + ".part", output)
    print(f"  {len(entries)} entries -> {os.path.basename(output)}")
    return True


def main():
    names = sys.argv[1:] or sorted(
        name for name in os.listdir(HERE) if name.endswith(".py") and name != os.path.basename(__file__)
    )
    for name in names:
        print(f"{name} ...", flush=True)
        convert(os.path.join(HERE, name))


if __name__ == "__main__":
    main()
