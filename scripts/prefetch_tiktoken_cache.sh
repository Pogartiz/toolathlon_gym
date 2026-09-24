#!/usr/bin/env bash
# Prefetch tiktoken encodings into .tiktoken_cache/ (mounted by runners).
# Usage: bash scripts/prefetch_tiktoken_cache.sh [docker_image]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="${TIKTOKEN_CACHE_DIR_HOST:-$ROOT/.tiktoken_cache}"
IMAGE="${1:-toolathlon-pack:local}"

mkdir -p "$CACHE_DIR"
echo "[prefetch] Filling $CACHE_DIR via $IMAGE ..."
docker run --rm \
  -e TIKTOKEN_CACHE_DIR=/opt/tiktoken_cache \
  -v "$CACHE_DIR:/opt/tiktoken_cache" \
  "$IMAGE" \
  python -c "import tiktoken; tiktoken.get_encoding('o200k_base'); tiktoken.get_encoding('cl100k_base'); print('ok', __import__('os').listdir('/opt/tiktoken_cache'))"

echo "[prefetch] Verifying offline ..."
docker run --rm --network=none \
  -e TIKTOKEN_CACHE_DIR=/opt/tiktoken_cache \
  -v "$CACHE_DIR:/opt/tiktoken_cache" \
  "$IMAGE" \
  python -c "import tiktoken; print(tiktoken.get_encoding('o200k_base').name, 'n_vocab=', tiktoken.get_encoding('o200k_base').n_vocab)"

echo "[prefetch] Done."
