#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
runtime="${1:-win-x64}"
case "$runtime" in win-x64|win-arm64) ;; *) echo '用法：package-windows.sh [win-x64|win-arm64]' >&2; exit 2 ;; esac
sdk="${MEMORY_GUARDIAN_DOTNET:-dotnet}"
cd "$repo/windows"
"$sdk" run --project MemoryGuardian.Core.Tests/MemoryGuardian.Core.Tests.csproj -c Release --disable-build-servers -p:UseSharedCompilation=false
output="$repo/dist/MemoryGuardian-$runtime"
"$sdk" publish MemoryGuardian.Windows/MemoryGuardian.Windows.csproj -c Release -r "$runtime" \
  --self-contained true -o "$output" --disable-build-servers -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false -p:UseSharedCompilation=false
test -f "$output/MemoryGuardian.exe"
cp README.md "$output/使用说明.md"
cp "$repo/scripts/verify-windows.ps1" "$output/自检.ps1"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, sys, zipfile
root = Path(sys.argv[1])
archive = root.parent / (root.name + '-preview.zip')
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
    for p in sorted(root.rglob('*')):
        if p.is_file(): z.write(p, p.relative_to(root))
with zipfile.ZipFile(archive) as z:
    if z.testzip() is not None or 'MemoryGuardian.exe' not in z.namelist():
        raise SystemExit('Invalid Windows archive')
print(json.dumps({'archive': str(archive), 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'bytes': archive.stat().st_size}))
PY
