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

with open(PID_FILE, "w") as f:
    f.write(str(os.getpid()))

import numpy as np
import torch
from kokoro import KPipeline

DEVICE = os.environ.get("TTS_DEVICE", "cuda" if torch.cuda.is_available() else "cpu")
pipe = KPipeline(lang_code="a", device=DEVICE)

# Warm up CUDA kernels and the model so the first real save isn't slow. Output is discarded.
for _ in pipe("Ready.", voice=VOICE, speed=SPEED):
    pass

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
    # Kokoro yields per sentence, so audio starts playing before the whole file is synthesized
    for _, _, audio in pipe(text, voice=VOICE, speed=SPEED):
        if cancel.is_set():
            break
        pcm = (np.clip(np.asarray(audio), -1.0, 1.0) * 32767).astype("<i2")
        out.write(pcm.tobytes())
        out.flush()
