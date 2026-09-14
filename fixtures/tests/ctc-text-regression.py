#!/usr/bin/env python3
"""Exercise transcript normalization before a fixture run reaches model inference."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from ctc_text import normalize_ctc_text

labels = ("-", "|", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "'")
parts, chars, events = normalize_ctc_text("Hold, hold! Don't cut two-second words.", labels)
assert [part["text"] for part in parts] == ["Hold,", "hold!", "Don't", "cut", "two-second", "words."]
assert "".join(chars) == "HOLD|HOLD|DON'T|CUT|TWO|SECOND|WORDS"
assert [event["character"] for event in events] == [",", "!", "-", "."]

for value in ("H0ld", "Hold🙂", "Hold | thought", "--", ""):
    try:
        normalize_ctc_text(value, labels)
    except ValueError:
        continue
    raise AssertionError("normalizer accepted unsupported input: " + repr(value))

print("ok CTC text normalization and rejection cases")
