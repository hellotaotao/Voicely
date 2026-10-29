#!/bin/zsh
# Xcode build phase: copies the speech models into the app's resources.
#   SpeechModel/         Qwen3-ASR: the MLX weights in the Mac (Catalyst) app,
#                        the CoreML models in the iPhone and iPad app
#   EnglishSpeechModel/  Parakeet TDT v2 (CoreML), the same on every platform
# The source folders come from scripts/fetch-speech-models.sh.
set -euo pipefail

if [[ "${IS_MACCATALYST:-NO}" == "YES" ]]; then
    VARIANT=mlx
else
    VARIANT=coreml
fi
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

if [[ ! -f "$SRCROOT/Models/$VARIANT/vocab.json" || ! -f "$SRCROOT/Models/$VARIANT/config.json"
      || ! -f "$SRCROOT/Models/parakeet/parakeet_vocab.json" ]]; then
    echo "error: A speech model is missing from $SRCROOT/Models. Run scripts/fetch-speech-models.sh once."
    exit 1
fi

# embed SOURCE_FOLDER DESTINATION_NAME
embed() {
    local source="$SRCROOT/Models/$1" dest="$RESOURCES/$2"
    # Skip the copy when the bundled model already matches the source.
    local stamp_file="$DERIVED_FILE_DIR/speech-model-$1.stamp"
    local stamp="$(cd "$source" && find . -type f -exec stat -f '%N %z %m' {} + | sort | shasum | cut -d' ' -f1)"
    if [[ -d "$dest" && -f "$stamp_file" && "$(cat "$stamp_file")" == "$stamp" ]]; then
        return
    fi
    rm -rf "$dest"
    mkdir -p "${dest:h}"
    # APFS clone when the build folder shares the volume, a plain copy otherwise.
    cp -cR "$source" "$dest" 2>/dev/null || cp -R "$source" "$dest"
    mkdir -p "$DERIVED_FILE_DIR"
    echo "$stamp" > "$stamp_file"
    echo "Embedded the $1 speech model ($(du -sh "$dest" | cut -f1))"
}

embed "$VARIANT" SpeechModel
embed parakeet EnglishSpeechModel
