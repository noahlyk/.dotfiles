#!/usr/bin/env python3
# Kokoro worker for tts-save.sh. Started once per nvim session.
#
# Reads utterance file paths from stdin, one per line. For each file it
# synthesizes the text and writes raw s16le mono PCM to stdout, which the
# launcher pipes into pw-cat. SIGUSR1 cancels the utterance in progress.
import os
import signal
import sys
import threading

cancel = threading.Event()
signal.signal(signal.SIGUSR1, lambda *_: cancel.set())

PID_FILE = sys.argv[1]
VOICE = os.environ.get("TTS_VOICE", "af_heart")
SPEED = float(os.environ.get("TTS_SPEED", "1.0"))
DEVICE = os.environ.get("TTS_DEVICE", "cuda")
RATE = 24000  # Kokoro output rate

with open(PID_FILE, "w") as f:
    f.write(str(os.getpid()))

import numpy as np
from kokoro import KPipeline

pipe = KPipeline(lang_code="a", device=DEVICE)
out = sys.stdout.buffer

while True:
    line = sys.stdin.readline()
    if not line:
        break  # launcher closed the FIFO: session is over
    cancel.clear()
    try:
        with open(line.strip(), encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        continue
    if not text.strip():
        continue
    for _, _, audio in pipe(text, voice=VOICE, speed=SPEED):
        if cancel.is_set():
            break
        pcm = (np.clip(np.asarray(audio), -1.0, 1.0) * 32767).astype("<i2")
        out.write(pcm.tobytes())
        out.flush()
