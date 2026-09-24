#!/usr/bin/env bash
# Builds ready-to-run hebfix binaries into dist/ (requires Go, only for building).
set -e
cd "$(dirname "$0")"
for target in linux/amd64 linux/arm64 linux/arm darwin/amd64 darwin/arm64; do
  os=${target%/*}; arch=${target#*/}
  echo "building $os/$arch"
  CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w" \
    -o "dist/hebfix-$os-$arch" .
done
