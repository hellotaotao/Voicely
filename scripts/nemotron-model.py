#!/usr/bin/env python3
"""Stage or verify the pinned Mac speaker model, without touching user data."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
REPO = "FluidInference/nemotron-3-diarization-coreml"
REVISION = "25a90f97f254428d4b30374b76af9c74fdee8327"
BUNDLE = "Nemotron3Diarizer_c128_split_w8a8.mlmodelc"
FILES = {
    "learnable_sil_emb.bin": (2_048, "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"),
    "pre_encode_proj_t.bin": (2_097_152, "eb15b89e7af9813331a7d8db02e83e30bf97463d272c748e72086bafd4e81c60"),
    f"{BUNDLE}/analytics/coremldata.bin": (243, "9522ac23edf90deb9bc4d3ef97ca435a90df499d346c4806351784b5a8decb60"),
    f"{BUNDLE}/coremldata.bin": (605, "777c6c6240baef5973b99b6984e9bb3a1f6a4812de28d3c65317be8911491421"),
    f"{BUNDLE}/model.mil": (759_134, "fdc429dae043fd0e10c9c91408a6002df6b90c71ef5c30877c56f7796abb6c53"),
    f"{BUNDLE}/weights/weight.bin": (99_249_792, "9a4c5de6ba011560713206b76c357d99ee596d1f1a58c66368b82834f9e12f95"),
}
NOTICES = {
    "LICENSE-OpenMDW-1.1.txt": ROOT / "Voicely/Licenses/OpenMDW-1.1.txt",
    "NOTICE.txt": ROOT / "scripts/nemotron-notice.txt",
}


def verify_asset(path, size, expected_sha256):
    if not path.is_file() or path.stat().st_size != size:
        raise ValueError(f"missing or incorrect size: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected_sha256:
        raise ValueError(f"SHA-256 mismatch: {path}")


def verify(directory):
    for path, (size, digest) in FILES.items():
        verify_asset(directory / path, size, digest)
    for path, expected in NOTICES.items():
        if (directory / path).read_bytes() != expected.read_bytes():
            raise ValueError(f"incorrect notice: {directory / path}")


def stage(destination, source):
    try:
        verify(destination)
        return
    except (OSError, ValueError):
        pass

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".nemotron-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        for name, (size, digest) in FILES.items():
            out = staging / name
            out.parent.mkdir(parents=True, exist_ok=True)
            if source is not None:
                shutil.copyfile(source / name, out)
            else:
                upstream = f"split/{name}" if name.startswith(f"{BUNDLE}/") else name
                url = f"https://huggingface.co/{REPO}/resolve/{REVISION}/{upstream}"
                print(f"downloading {REPO}/{upstream} ({size / 1e6:.1f} MB)", flush=True)
                with urllib.request.urlopen(url, timeout=60) as response, out.open("wb") as handle:
                    shutil.copyfileobj(response, handle, 1024 * 1024)
            verify_asset(out, size, digest)

        for name, original in NOTICES.items():
            shutil.copyfile(original, staging / name)
        # Publish only after all bytes are verified; leave unrelated files alone.
        for name in (*FILES, *NOTICES):
            out = destination / name
            out.parent.mkdir(parents=True, exist_ok=True)
            os.replace(staging / name, out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", type=Path, metavar="DIRECTORY", help="only verify already staged assets")
    parser.add_argument("--source", type=Path, metavar="DIRECTORY", help="stage from an existing local model instead of downloading")
    parser.add_argument("--destination", type=Path, default=ROOT / "Models/nemotron")
    args = parser.parse_args()
    try:
        if args.verify is not None:
            verify(args.verify)
        else:
            stage(args.destination, args.source)
            print(f"{args.destination}: {sum(size for size, _ in FILES.values()) / 1e6:.0f} MB")
    except (OSError, ValueError) as error:
        parser.exit(1, f"Nemotron model: {error}\n")


if __name__ == "__main__":
    main()
