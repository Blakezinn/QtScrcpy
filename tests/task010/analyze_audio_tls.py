# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
"""Check 500 ms RMS windows in a live or finished PCM S16LE mono WAV."""

import math
import pathlib
import struct
import sys


def inspect(filename):
    raw = pathlib.Path(filename).read_bytes()
    if len(raw) < 44 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError("invalid WAV header")
    if raw[12:16] != b"fmt " or raw[36:40] != b"data":
        raise ValueError("unexpected WAV format")
    coding, channels, rate, _, block_align, bits = struct.unpack_from("<HHIIHH", raw, 20)
    if coding != 1 or channels != 1 or bits != 16 or block_align != 2:
        raise ValueError("not mono signed PCM16")
    if rate not in (8000, 16000, 44100, 48000):
        raise ValueError("unsupported PCM sample rate")

    # The session may still be recording: its RIFF length is finalized on stop.
    # Read the actual received sample bytes without trusting that length.
    samples = memoryview(raw)[44:]
    window_samples = rate // 2
    available = len(samples) // (window_samples * 2)
    print("PCM_RATE=%d" % rate)
    print("PCM_BYTES=%d" % len(samples))
    print("HALF_SECOND_WINDOWS=%d" % available)
    if available < 10:
        raise ValueError("fewer than 5 seconds of PCM")
    quiet = 0
    # Ignore only the first 500 ms of decoder/jitter ramp-up.
    for index in range(1, 10):
        begin = index * window_samples * 2
        end = begin + window_samples * 2
        block = samples[begin:end]
        values = struct.unpack("<%dh" % window_samples, block)
        rms = math.sqrt(sum((value / 32768.0) ** 2 for value in values) / window_samples)
        ok = rms >= 0.01
        quiet += int(not ok)
        print("RMS_500MS_%d=%.6f %s" % (index, rms, "PASS" if ok else "FAIL"))
    print("RMS_WINDOWS_QUIET=%d" % quiet)
    print("RMS_CONTINUITY_PASS=%s" % str(quiet == 0).lower())
    return 0 if quiet == 0 else 5


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("usage: analyze_audio_tls.py audio_tls.wav")
        sys.exit(inspect(sys.argv[1]))
    except (ValueError, OSError, struct.error) as exc:
        print("RMS_ANALYSIS_ERROR=%s" % exc)
        sys.exit(4)
