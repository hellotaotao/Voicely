#!/usr/bin/env python3
"""Build the invented sample library that the Debug build shows in demo mode.

Reads notes.json next to this script. Notes whose sentences name a voice get
real audio from macOS `say`, joined with short pauses, so playback, the
waveform and tap-to-play line up with the text. Writes library.json and the
audio files into the output directory.

The app is sandboxed, so the output has to be inside its container:

  DIR=~/Library/Containers/com.hellotaotao.Voicely/Data/tmp/demo-library
  scripts/demo-library/make-demo-library.py "$DIR"
  NSUnbufferedIO=YES VOICELY_DEMO_DIR="$DIR" <DerivedData>/Debug-maccatalyst/Voicely.app/Contents/MacOS/Voicely

Quit the installed Voicely first; it shares the bundle identifier.
"""

import json
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

PAUSE_SECONDS = 0.45
SAMPLE_RATE = 22050


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def build_audio(note: dict, out_dir: Path) -> tuple[str, list[dict]]:
    timed = []
    frames = bytearray()
    pause = bytes(int(SAMPLE_RATE * PAUSE_SECONDS) * 2)
    with tempfile.TemporaryDirectory() as tmp:
        for index, sentence in enumerate(note["sentences"]):
            piece = Path(tmp) / f"s{index}.wav"
            run("say", "-v", sentence["voice"], f"--data-format=LEI16@{SAMPLE_RATE}", "-o", str(piece), sentence["text"])
            with wave.open(str(piece)) as reader:
                assert reader.getnchannels() == 1 and reader.getsampwidth() == 2
                audio = reader.readframes(reader.getnframes())
            start = len(frames) / 2 / SAMPLE_RATE
            frames += audio
            timed.append({"text": sentence["text"], "start": round(start, 3), "end": round(len(frames) / 2 / SAMPLE_RATE, 3)})
            frames += pause
        joined = Path(tmp) / "joined.wav"
        with wave.open(str(joined), "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(SAMPLE_RATE)
            writer.writeframes(bytes(frames))
        name = f"{note['id']}.m4a"
        run("afconvert", "-f", "m4af", "-d", "aac", str(joined), str(out_dir / name))
    return name, timed


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out_dir = Path(sys.argv[1]).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    source = json.loads((Path(__file__).parent / "notes.json").read_text())

    notes = []
    for note in source["notes"]:
        entry = {key: note[key] for key in ("title", "hoursAgo", "folderSlot", "engine")}
        if all("voice" in sentence for sentence in note["sentences"]):
            entry["audioFile"], entry["sentences"] = build_audio(note, out_dir)
        else:
            entry["durationSeconds"] = note["durationSeconds"]
            entry["sentences"] = [{"text": sentence["text"]} for sentence in note["sentences"]]
        notes.append(entry)

    library = {"folders": source["folders"], "notes": notes}
    (out_dir / "library.json").write_text(json.dumps(library, ensure_ascii=False, indent=2))
    print(f"Wrote {len(notes)} notes to {out_dir}")


if __name__ == "__main__":
    main()
