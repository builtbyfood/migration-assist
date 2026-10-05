# Morpheus task loader for Invoke-VMwareToVirtio.ps1
# Keeps the task body tiny so Morpheus' elevated WinRM wrapper (powershell.exe -encodedcommand) stays under
# the 32,767-character Windows command-line limit. Fetches the full script, verifies it, runs it from disk.

$ScriptUrl      = 'http://your-web-server/Invoke-VMwareToVirtio.ps1'   # http(s) URL to the full script
$ExpectedSha256 = 'F54C149E1EB962C617D145E9FDFD38E3EB6AA1017D2783FC7C327CEF0AE0F825'   # 1.4.0; '' to skip

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$dir  = Join-Path $env:ProgramData 'VMwareToVirtio'
$dest = Join-Path $dir 'Invoke-VMwareToVirtio.ps1'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $dest -UseBasicParsing -TimeoutSec 120
} catch {
    Write-Output "Could not download $ScriptUrl : $($_.Exception.Message)"
    exit 1
}

if ($ExpectedSha256) {
    $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256.ToUpper()) {
        Write-Output "SHA-256 mismatch: expected $ExpectedSha256, got $actual. Not running it."
        exit 1
    }
}

& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $dest
exit $LASTEXITCODE
