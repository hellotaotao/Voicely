#!/bin/zsh
# Fetches the speech models the app ships with into Models/ (not in git).
#
#   Models/mlx/       Qwen3-ASR MLX 8-bit weights for the Mac app
#   Models/coreml/    Qwen3-ASR CoreML models for the iPhone and iPad app
#   Models/parakeet/  Parakeet TDT v2 CoreML models (English) for every platform
#
# The Qwen3-ASR folders carry the tokenizer files. Files already in the
# Hugging Face cache that speech-swift uses (~/Library/Caches/qwen3-speech) or
# in FluidAudio's model folder are cloned instead of downloaded. The revisions
# are pinned; change them on purpose.
#
# Usage: scripts/fetch-speech-models.sh
set -euo pipefail

ROOT="${0:A:h:h}"
DEST="$ROOT/Models"

exec /usr/bin/python3 -I - "$DEST" <<'PYTHON'
import json, os, shutil, subprocess, sys, urllib.request

dest = sys.argv[1]
qwen_cache = os.path.expanduser("~/Library/Caches/qwen3-speech/models")
fluid_cache = os.path.expanduser("~/Library/Application Support/FluidAudio/Models")

MLX = ("mlx-community/Qwen3-ASR-0.6B-8bit", "89e96d92ba34aca20b3e29fb10cc284097d1219f")
COREML = ("aufklarer/Qwen3-ASR-CoreML", "8c6bc87b87856930b435550e94ce47de710ce4ed")
TOKENIZER = ["vocab.json", "merges.txt", "tokenizer_config.json"]
COREML_BUNDLES = ["encoder.mlmodelc", "embedding.mlmodelc", "decoder_part1.mlmodelc", "decoder_part2.mlmodelc"]
PARAKEET = ("FluidInference/parakeet-tdt-0.6b-v2-coreml", "ee09c569f73759e6d44c9bd16766f477b2b36d39")
PARAKEET_BUNDLES = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc"]

def tree(repo, revision):
    url = f"https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true"
    with urllib.request.urlopen(url) as response:
        return {item["path"]: item.get("size", 0) for item in json.load(response) if item["type"] == "file"}

def fetch(repo, revision, files, sizes, target, cache):
    for path in files:
        out = os.path.join(target, path)
        if os.path.exists(out) and os.path.getsize(out) == sizes[path]:
            continue
        os.makedirs(os.path.dirname(out), exist_ok=True)
        cached = os.path.join(cache, path)
        if os.path.exists(cached) and os.path.getsize(cached) == sizes[path]:
            if os.path.exists(out):
                os.remove(out)
            # APFS clone: instant and takes no extra space.
            subprocess.run(["cp", "-c", cached, out], check=True)
            continue
        print(f"downloading {repo}/{path} ({sizes[path] / 1e6:.0f} MB)", flush=True)
        url = f"https://huggingface.co/{repo}/resolve/{revision}/{path}"
        with urllib.request.urlopen(url) as response, open(out + ".part", "wb") as handle:
            shutil.copyfileobj(response, handle, 1 << 20)
        os.replace(out + ".part", out)
        if os.path.getsize(out) != sizes[path]:
            sys.exit(f"size mismatch for {repo}/{path}")

mlx_sizes = tree(*MLX)
coreml_sizes = tree(*COREML)

mlx_files = ["config.json", "model.safetensors", "model.safetensors.index.json"] + TOKENIZER
fetch(*MLX, mlx_files, mlx_sizes, os.path.join(dest, "mlx"), os.path.join(qwen_cache, MLX[0]))

coreml_files = ["config.json"] + [p for p in coreml_sizes if p.split("/")[0] in COREML_BUNDLES]
fetch(*COREML, coreml_files, coreml_sizes, os.path.join(dest, "coreml"), os.path.join(qwen_cache, COREML[0]))
fetch(*MLX, TOKENIZER, mlx_sizes, os.path.join(dest, "coreml"), os.path.join(qwen_cache, MLX[0]))

parakeet_sizes = tree(*PARAKEET)
parakeet_files = ["parakeet_vocab.json"] + [p for p in parakeet_sizes if p.split("/")[0] in PARAKEET_BUNDLES]
fetch(*PARAKEET, parakeet_files, parakeet_sizes, os.path.join(dest, "parakeet"),
      os.path.join(fluid_cache, "parakeet-tdt-0.6b-v2"))

for name in ("mlx", "coreml", "parakeet"):
    folder = os.path.join(dest, name)
    total = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(folder) for f in fs)
    print(f"Models/{name}: {total / 1e6:.0f} MB")
PYTHON
