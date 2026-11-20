# Runs PlatformIO for this project with the settings this PC needs.
#   .\tools\pio.ps1 run                              build
#   .\tools\pio.ps1 run -t upload --upload-port COM3 build and flash
#   .\tools\pio.ps1 device monitor -p COM3           serial console
#
# - The core lives in C:\pio: the default %USERPROFILE%\.platformio paths are
#   too long for Windows without long-path support.
# - PlatformIO is in the venv C:\pio\venv (pip install platformio).
# - MSYSTEM must be unset: pioarduino's tool installer refuses to run when it
#   looks like MSYS/Git Bash.
$ErrorActionPreference = 'Stop'
$env:PLATFORMIO_CORE_DIR = 'C:\pio'
$env:MSYSTEM = $null
$pio = 'C:\pio\venv\Scripts\pio.exe'
if (-not (Test-Path $pio)) {
    Write-Error "PlatformIO not found at $pio. Install it: py -3 -m venv C:\pio\venv; C:\pio\venv\Scripts\python -m pip install platformio"
}
Push-Location (Split-Path $PSScriptRoot -Parent)
try { & $pio @args; exit $LASTEXITCODE } finally { Pop-Location }
