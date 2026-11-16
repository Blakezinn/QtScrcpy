# Copyright 2026 qtscrcpy-net contributors.
# SPDX-License-Identifier: Apache-2.0
"""Inspect 1-second PCM S16LE mono WAV chunks by zero crossings and RMS."""

import math
import struct
import sys


def load(path):
    with open(path, "rb") as handle:
        blob = handle.read()
    if len(blob) < 44 or blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
        raise ValueError("NOT_WAV")
    offset = 12
    rate = None
    payload = None
    while offset + 8 <= len(blob):
        ident, length = struct.unpack_from("<4sI", blob, offset)
        offset += 8
        if offset + length > len(blob):
            raise ValueError("WAV_TRUNCATED")
        chunk = blob[offset:offset + length]
        if ident == b"fmt ":
            if length < 16:
                raise ValueError("BAD_FMT")
            encoding, channels, rate, _, alignment, bits = struct.unpack_from(
                "<HHIIHH", chunk)
            if encoding != 1 or channels != 1 or bits != 16 or alignment != 2:
                raise ValueError("WAV_NOT_MONO_PCM16")
        elif ident == b"data":
            payload = chunk
        offset += length + length % 2
    if rate not in (8000, 16000, 44100, 48000) or payload is None:
        raise ValueError("WAV_MISSING_PCM")
    return rate, payload


def analyze(rate, payload):
    consecutive = 0
    best = 0
    print("segment second frequency_hz rms result")
    whole = len(payload) // (rate * 2)
    for i in range(whole):
        chunk = payload[i * rate * 2: (i + 1) * rate * 2]
        samples = struct.unpack("<" + "h" * rate, chunk)
        zero_crossings = sum(
            1 for j in range(1, len(samples))
            if (samples[j - 1] < 0 <= samples[j])
            or (samples[j - 1] >= 0 > samples[j])
        )
        freq = zero_crossings / 2.0
        rms = math.sqrt(sum((sample / 32768.0) ** 2 for sample in samples) / rate)
        passes = 400 <= freq <= 480 and rms >= 0.02
        consecutive = consecutive + 1 if passes else 0
        best = max(best, consecutive)
        print("%d %d %.2f %.5f %s" % (i, i, freq, rms, "PASS" if passes else "FAIL"))
    print("AUDIO_SEGMENTS_TOTAL=%d" % whole)
    print("AUDIO_CONSECUTIVE_VALID=%d" % best)
    print("AUDIO_ANALYSIS_PASS=%s" % str(best >= 3).lower())
    return 0 if best >= 3 else 5


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("USAGE: analyze_audio.py audio.wav")
        sample_rate, data = load(sys.argv[1])
        print("AUDIO_RATE=%d" % sample_rate)
        print("AUDIO_PCM_BYTES=%d" % len(data))
        sys.exit(analyze(sample_rate, data))
    except (ValueError, OSError, struct.error) as error:
        print("AUDIO_ANALYSIS_ERROR=%s" % error)
        sys.exit(4)
