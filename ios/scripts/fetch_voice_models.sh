#!/usr/bin/env bash
# Downloads the on-device voice assets needed for the Neuphonic coach voice.
# Idempotent: anything already present (and plausibly complete) is skipped.
# Hugging Face downloads require HF_TOKEN in the environment.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$IOS_DIR/Vendor"
MODELS_DIR="$IOS_DIR/Jogga/VoiceModels"
mkdir -p "$VENDOR_DIR" "$MODELS_DIR"

LLAMA_TAG="b11000"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-xcframework.zip"
GGUF_URL="https://huggingface.co/neuphonic/neutts-2e-q4-gguf/resolve/main/neutts-2e-Q4_0.gguf"
CODEC_URL="https://huggingface.co/neuphonic/neucodec-onnx-decoder-int8/resolve/main/model.onnx"
LICENSE_URL="https://huggingface.co/neuphonic/neutts-2e-q4-gguf/resolve/main/LICENSE"
SRC_URL="https://github.com/ggml-org/llama.cpp/archive/refs/tags/${LLAMA_TAG}.tar.gz"

# Files under 1 MB are almost certainly Hugging Face gate error pages.
check_size() { # path — exits non-zero if missing or suspiciously small
    [ -f "$1" ] && [ "$(stat -f%z "$1")" -ge 1000000 ]
}

hf_curl() { # url dest
    if [ -z "${HF_TOKEN:-}" ]; then
        echo "error: HF_TOKEN is not set (needed for $1)" >&2
        exit 1
    fi
    curl -sfL -H "Authorization: Bearer $HF_TOKEN" -o "$2" "$1" || {
        echo "error: download failed: $1 (check HF_TOKEN and repo access)" >&2
        rm -f "$2"
        exit 1
    }
}

if [ -d "$VENDOR_DIR/llama.xcframework" ]; then
    echo "llama.xcframework: present, skipping"
else
    echo "Downloading llama $LLAMA_TAG xcframework..."
    tmp="$(mktemp -d)"
    curl -sfL -o "$tmp/llama.zip" "$LLAMA_URL"
    unzip -oq "$tmp/llama.zip" -d "$tmp"
    mv "$tmp/build-apple/llama.xcframework" "$VENDOR_DIR/llama.xcframework"

    # Upstream ships no ios-arm64-simulator slice; build one from the same tag
    # and repack so the app + tests also run on the simulator.
    echo "Building ios-arm64-simulator slice from llama.cpp $LLAMA_TAG..."
    curl -sfL -o "$tmp/src.tar.gz" "$SRC_URL"
    tar -xzf "$tmp/src.tar.gz" -C "$tmp"
    src="$tmp/llama.cpp-$LLAMA_TAG"
    cmake -S "$src" -B "$tmp/build" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphonesimulator \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=OFF \
        -DGGML_BLAS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_TOOLS=OFF \
        -DLLAMA_BUILD_SERVER=OFF \
        > "$tmp/cmake.log" 2>&1
    cmake --build "$tmp/build" --target llama -j "$(sysctl -n hw.ncpu)" \
        >> "$tmp/cmake.log" 2>&1

    # Force-load the static archives into a single dylib matching the
    # upstream framework's install name.
    mkdir -p "$tmp/llama.framework"
    clang++ -arch arm64 \
        -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
        -dynamiclib -o "$tmp/llama.framework/llama" \
        -install_name "@rpath/llama.framework/llama" \
        -all_load \
        "$tmp/build/src/libllama.a" \
        "$tmp/build/ggml/src/libggml.a" \
        "$tmp/build/ggml/src/libggml-base.a" \
        "$tmp/build/ggml/src/libggml-cpu.a" \
        -framework Accelerate -framework Foundation -lc++
    cp -R "$VENDOR_DIR/llama.xcframework/ios-arm64/llama.framework/Headers" \
          "$VENDOR_DIR/llama.xcframework/ios-arm64/llama.framework/Modules" \
          "$VENDOR_DIR/llama.xcframework/ios-arm64/llama.framework/Info.plist" \
          "$tmp/llama.framework/"

    mv "$VENDOR_DIR/llama.xcframework" "$tmp/llama.xcframework"
    xcodebuild -create-xcframework \
        -framework "$tmp/llama.xcframework/ios-arm64/llama.framework" \
        -framework "$tmp/llama.xcframework/macos-arm64_x86_64/llama.framework" \
        -framework "$tmp/llama.framework" \
        -output "$VENDOR_DIR/llama.xcframework"
    rm -rf "$tmp"
fi

fetch_model() { # url dest name
    if check_size "$2"; then
        echo "$3: present, skipping"
    else
        rm -f "$2" # drop any gate error page
        echo "Downloading $3..."
        hf_curl "$1" "$2"
        check_size "$2" || {
            echo "error: $3 is under 1 MB after download — likely a gate error page" >&2
            rm -f "$2"
            exit 1
        }
    fi
}

fetch_model "$GGUF_URL" "$MODELS_DIR/neutts-2e-Q4_0.gguf" "NeuTTS-2E backbone"
fetch_model "$CODEC_URL" "$MODELS_DIR/neucodec-int8.onnx" "NeuCodec decoder"

if [ -f "$MODELS_DIR/NEUTTS_LICENSE" ]; then
    echo "NEUTTS_LICENSE: present, skipping"
else
    hf_curl "$LICENSE_URL" "$MODELS_DIR/NEUTTS_LICENSE"
fi

echo "Done. VoiceModels: $(du -sh "$MODELS_DIR" | cut -f1), Vendor: $(du -sh "$VENDOR_DIR" | cut -f1)"
