#!/bin/zsh
# Packages Parakeet Ultra (Models/parakeet, from scripts/fetch-speech-models.sh)
# as the Apple-hosted asset pack the iPhone and iPad app download after install
# (Voicely/EnglishModelAssetPack.swift). Upload the archive to App Store
# Connect separately from the app, with Transporter or
# `xcrun altool --upload-asset-pack`. A changed model needs a new pack version.
#
# Usage: scripts/package-english-model-pack.sh [OUTPUT.aar]
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="${1:-$ROOT/build/asset-packs/EnglishSpeechModel.aar}"

if [[ ! -d "$ROOT/Models/parakeet/JointDecisionv3.mlmodelc" || ! -f "$ROOT/Models/parakeet/parakeet_vocab.json" ]]; then
    echo "error: Models/parakeet is missing. Run scripts/fetch-speech-models.sh once." >&2
    exit 1
fi

mkdir -p "${OUTPUT:h}"
xcrun ba-package package "$ROOT/scripts/english-model-pack.json" --output-path "$OUTPUT"
ls -l "$OUTPUT"
