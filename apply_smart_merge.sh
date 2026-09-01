#!/usr/bin/env bash
set -euo pipefail

SM="smart-src"

echo "=== Finding smart files in source ===="
find "$SM" -path "$SM/.git" -prune -o -type d -iname '*smart*' -print 2>/dev/null | head -20
find "$SM" -path "$SM/.git" -prune -o -type f -name 'smart*.go' -print 2>/dev/null | head -40

# 检查源仓库里已有的 smart 相关目录
for d in common/smart common/assetdl experimental/smart experimental/geox option; do
  if [ -d "$SM/$d" ]; then
    echo "source has dir: $SM/$d"
  else
    echo "MISSING dir: $SM/$d  (skipping copy for this dir)"
  fi
done

echo "=== Copying smart code into core ==="
cp -r "$SM/common/smart"     core/common/smart
cp -r "$SM/common/assetdl"   core/common/assetdl
cp -r "$SM/experimental/smart" core/experimental/smart
cp -r "$SM/experimental/geox"  core/experimental/geox
cp "$SM/option/smart.go"     core/option/smart.go

# smart 出站本体：protocol/group 下所有 smart 开头的 .go
shopt -s nullglob
for f in "$SM"/protocol/group/smart*.go; do
  echo "copy group file: $(basename "$f")"
  cp "$f" core/protocol/group/
done
shopt -u nullglob

# clashapi 的 smart 支持
cp "$SM/experimental/clashapi/smart.go" core/experimental/clashapi/ 2>/dev/null || \
  echo "no clashapi/smart.go (ok if absent)"

# urltest 升级为带 detail 的版本（smart 依赖）
cp "$SM/common/urltest/urltest.go"            core/common/urltest/urltest.go
cp "$SM/common/urltest/expected_status.go"    core/common/urltest/expected_status.go 2>/dev/null || \
  echo "no expected_status.go (ok if absent)"

echo "=== Copied smart files in core ==="
find core -path core/.git -prune -o -name '*smart*' -print 2>/dev/null | head -40
echo "APPLY_DONE"
