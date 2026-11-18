"""Lab 044: where the beeps start in a decoded WAV (16-bit), in ms. The test track has a short beep every second
at exact times; comparing these onsets with the times they were written gives the sound's delay in the file."""
import json
import struct
import sys
import wave


def onsets(path, threshold=3000):
    w = wave.open(path, "rb")
    rate, channels, n = w.getframerate(), w.getnchannels(), w.getnframes()
    raw = w.readframes(n)
    samples = struct.unpack("<%dh" % (len(raw) // 2), raw)[::channels]
    found, last = [], -rate
    for i, s in enumerate(samples):
        if abs(s) > threshold and i - last > rate // 2:
            found.append(round(i * 1000 / rate, 2))
            last = i
    return found


if __name__ == "__main__":
    print(json.dumps(onsets(sys.argv[1])))
