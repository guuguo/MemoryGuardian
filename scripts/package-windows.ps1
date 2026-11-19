param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$project = Join-Path $repo 'windows/MemoryGuardian.Windows/MemoryGuardian.Windows.csproj'
$output = Join-Path $repo "dist/MemoryGuardian-$Runtime"
$archive = Join-Path $repo "dist/MemoryGuardian-$Runtime-preview.zip"
Push-Location (Join-Path $repo 'windows')
try {
    if (-not $SkipTests) {
        & dotnet run --project 'MemoryGuardian.Core.Tests/MemoryGuardian.Core.Tests.csproj' -c Release --disable-build-servers -p:UseSharedCompilation=false
        if ($LASTEXITCODE -ne 0) { throw '核心测试失败' }
    }
    & dotnet publish $project -c Release -r $Runtime --self-contained true -o $output --disable-build-servers `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:PublishTrimmed=false `
        -p:DebugType=None -p:DebugSymbols=false -p:UseSharedCompilation=false
    if ($LASTEXITCODE -ne 0) { throw 'Windows 发布构建失败' }
    if (-not (Test-Path (Join-Path $output 'MemoryGuardian.exe'))) { throw '缺少 EXE 产物' }
    Copy-Item (Join-Path $repo 'windows/README.md') (Join-Path $output '使用说明.md') -Force
    Copy-Item (Join-Path $repo 'scripts/verify-windows.ps1') (Join-Path $output '自检.ps1') -Force
    Compress-Archive -Path (Join-Path $output '*') -DestinationPath $archive -Force
    Get-FileHash $archive -Algorithm SHA256
    Write-Host "预览包：$archive"
} finally { Pop-Location }
