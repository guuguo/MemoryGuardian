param([string]$Executable, [string]$Report)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$portable = Test-Path (Join-Path $PSScriptRoot 'MemoryGuardian.exe')
if (-not $Executable) {
    if ($portable) { $Executable = Join-Path $PSScriptRoot 'MemoryGuardian.exe' }
    else { $Executable = Join-Path $repo 'dist/MemoryGuardian-win-x64/MemoryGuardian.exe' }
}
if (-not $Report) {
    if ($portable) { $Report = Join-Path $PSScriptRoot 'windows-self-test.json' }
    else { $Report = Join-Path $repo 'dist/windows-self-test.json' }
}
if (-not (Test-Path $Executable)) { throw "可执行文件不存在：$Executable" }
$Executable = (Resolve-Path $Executable).Path
$Report = [System.IO.Path]::GetFullPath($Report)
# Fixed output is a test artifact. Remove it first so a failed launch cannot reuse stale success evidence.
if (Test-Path $Report) { Remove-Item $Report }
$process = Start-Process -FilePath $Executable -ArgumentList @('--self-test', ('"' + $Report + '"')) -PassThru
if (-not $process.WaitForExit(30000)) {
    $process.Kill() # Only the child launched by this self-test script, never a monitored application.
    throw '原生自检超过 30 秒'
}
if (-not (Test-Path $Report)) { throw '未生成自检报告' }
$data = Get-Content $Report -Raw | ConvertFrom-Json
if ($process.ExitCode -ne 0 -or -not $data.passed) { throw "自检未通过，请查看 $Report" }
Get-Content $Report -Raw
Write-Host '原生采样自检通过；界面、托盘、退出请求和资源持续观测仍需人工验收。'
