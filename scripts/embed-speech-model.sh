#!/bin/zsh
# Xcode build phase: copies the speech model into the app's resources as
# SpeechModel/. The Mac (Catalyst) app gets the MLX weights, the iPhone and
# iPad app the CoreML models. The source folders come from
# scripts/fetch-speech-models.sh.
set -euo pipefail

if [[ "${IS_MACCATALYST:-NO}" == "YES" ]]; then
    VARIANT=mlx
else
    VARIANT=coreml
fi
SOURCE="$SRCROOT/Models/$VARIANT"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/SpeechModel"

if [[ ! -f "$SOURCE/vocab.json" || ! -f "$SOURCE/config.json" ]]; then
    echo "error: The speech model is missing from $SOURCE. Run scripts/fetch-speech-models.sh once."
    exit 1
fi

# Skip the copy when the bundled model already matches the source.
STAMP_FILE="$DERIVED_FILE_DIR/speech-model-$VARIANT.stamp"
STAMP="$(cd "$SOURCE" && find . -type f -exec stat -f '%N %z %m' {} + | sort | shasum | cut -d' ' -f1)"
if [[ -d "$DEST" && -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$STAMP" ]]; then
    exit 0
fi

rm -rf "$DEST"
mkdir -p "${DEST:h}"
# APFS clone when the build folder shares the volume, a plain copy otherwise.
cp -cR "$SOURCE" "$DEST" 2>/dev/null || cp -R "$SOURCE" "$DEST"
mkdir -p "$DERIVED_FILE_DIR"
echo "$STAMP" > "$STAMP_FILE"
echo "Embedded the $VARIANT speech model ($(du -sh "$DEST" | cut -f1))"
