"""Print microphone level (0.0-1.0) about 25 times per second.

Runs pw-record on the source named in argv[1] (default source if missing or
empty) and reads raw 16 kHz mono s16 audio.
Exits when stdout closes, and pw-record dies with this process.
"""
import array
import ctypes
import math
import signal
import subprocess
import sys

RATE = 16000
CHUNK = RATE // 25  # samples per reading


def source_args(source):
    """pw-record args; "sink:NAME" records what plays to NAME (tests)."""
    if not source:
        return []
    if source.startswith("sink:"):
        return ["-P", "{ stream.capture.sink=true }", "--target", source[5:]]
    return ["--target", source]


def die_with_parent():
    ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG


def main():
    proc = subprocess.Popen(
        ["pw-record", "--raw", "--rate", str(RATE), "--channels", "1", "--format", "s16",
         *source_args(sys.argv[1] if len(sys.argv) > 1 else ""), "-"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        preexec_fn=die_with_parent,
    )
    try:
        while True:
            data = proc.stdout.read(CHUNK * 2)
            if not data:
                break
            samples = array.array("h", data[: len(data) // 2 * 2])
            if not samples:
                continue
            rms = math.sqrt(sum(s * s for s in samples) / len(samples)) / 32768
            db = 20 * math.log10(rms) if rms > 0 else -90
            level = min(1.0, max(0.0, (db + 55) / 45))  # -55 dB silent, -10 dB full
            sys.stdout.write(f"{level:.3f}\n")
            sys.stdout.flush()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
