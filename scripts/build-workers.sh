#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cache="$project_dir/.build/remeet-workers"
downloads="$cache/downloads"
mkdir -p "$downloads"

fetch() {
    local filename="$1" url="$2" checksum="$3" path
    path="$downloads/$filename"
    if [[ ! -f "$path" ]]; then
        printf 'Downloading %s\n' "$filename" >&2
        curl --fail --location --silent --show-error --retry 3 --output "$path.part" "$url"
        if ! printf '%s  %s\n' "$checksum" "$path.part" | shasum -a 256 -c --status; then
            rm -f "$path.part"
            printf 'Checksum mismatch for %s\n' "$url" >&2
            exit 1
        fi
        mv "$path.part" "$path"
    fi
    if ! printf '%s  %s\n' "$checksum" "$path" | shasum -a 256 -c --status; then
        printf 'Checksum mismatch. Remove %s and build again.\n' "$path" >&2
        exit 1
    fi
}

whisper_archive=whisper-v1.8.3.tar.gz
llama_archive=llama-b6500-macos-arm64.zip
sherpa_archive=sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts.tar.bz2
fetch "$whisper_archive" https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.8.3 \
    870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a
fetch "$llama_archive" https://github.com/ggml-org/llama.cpp/releases/download/b6500/llama-b6500-bin-macos-arm64.zip \
    4f34ae19823ee22e8036d6da91f083ca62ab926c2a0a4a5ce9df34897360087b
fetch "$sherpa_archive" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/$sherpa_archive" \
    4fcc6c77c8d8d2e2f04cfdc17c6fd224c01469b78529370eb9d8e0e5ec97ac79
fetch sherpa-onnx-v2.0.1-LICENSE https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1/LICENSE \
    cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
fetch onnxruntime-v1.28.2-LICENSE https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/LICENSE \
    2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
fetch onnxruntime-v1.28.2-ThirdPartyNotices.txt https://raw.githubusercontent.com/microsoft/onnxruntime/v1.28.2/ThirdPartyNotices.txt \
    0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2

work="$(mktemp -d "$cache/.stage.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{Helpers,Frameworks,Licenses} "$cache/whisper-src"
if [[ ! -f "$cache/whisper-src/.extracted-v1.8.3" ]]; then
    tar -xzf "$downloads/$whisper_archive" -C "$cache/whisper-src" --strip-components=1
    touch "$cache/whisper-src/.extracted-v1.8.3"
fi
cmake -S "$cache/whisper-src" -B "$cache/whisper-build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF >&2
cmake --build "$cache/whisper-build" --target whisper-cli --parallel 6 >&2

unzip -oq "$downloads/$llama_archive" -d "$work"
tar -xjf "$downloads/$sherpa_archive" -C "$work"
llama="$work/build/bin"
sherpa="$work/${sherpa_archive%.tar.bz2}"
install -m 755 "$cache/whisper-build/bin/whisper-cli" "$llama/llama-cli" \
    "$sherpa/bin/sherpa-onnx-offline-speaker-diarization" "$work/Helpers/"
install -m 755 "$llama/libllama.dylib" "$llama"/libggml*.dylib \
    "$sherpa/lib/libonnxruntime.dylib" "$work/Frameworks/"
install -m 644 "$cache/whisper-src/LICENSE" "$work/Licenses/whisper.cpp-LICENSE"
for license in "$llama"/LICENSE*; do
    install -m 644 "$license" "$work/Licenses/llama.cpp-$(basename "$license")"
done
install -m 644 "$downloads/sherpa-onnx-v2.0.1-LICENSE" \
    "$downloads/onnxruntime-v1.28.2-LICENSE" "$downloads/onnxruntime-v1.28.2-ThirdPartyNotices.txt" \
    "$work/Licenses/"

for worker in llama-cli sherpa-onnx-offline-speaker-diarization; do
    xcrun install_name_tool -add_rpath @executable_path/../Frameworks "$work/Helpers/$worker"
    codesign --force --sign - --timestamp=none "$work/Helpers/$worker" >&2
done

for directory in Helpers Frameworks Licenses; do
    mkdir -p "$cache/$directory"
    cp -R "$work/$directory/." "$cache/$directory/"
done
printf '%s\n' "$cache"
