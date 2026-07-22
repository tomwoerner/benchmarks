[CmdletBinding()]
param(
    [switch]$InstallDependencies,
    [switch]$InstallMlc,
    [switch]$AcceptIntelLicense,
    [switch]$InstallPassMark,
    [switch]$SkipMlc,
    [Int64]$StreamArraySize = 50000000,
    [int]$NTimes = 10,
    [string]$OutputRoot = "$HOME\benchmarks\memory"
)

$ErrorActionPreference = "Stop"
$StreamCommit = "6703f7504a38a8da96b353cadafa64d3c2d7a2d3"
$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$HostNameSafe = $env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]', '_'
$OutDir = Join-Path $OutputRoot "${HostNameSafe}_${Stamp}"
$ToolsDir = Join-Path $OutDir "tools"
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force | Out-Null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-PerformanceTest {
    $candidates = @(
        "$env:ProgramFiles\PerformanceTest\PerformanceTest64.exe",
        "$env:ProgramFiles\PerformanceTest\PerformanceTest.exe",
        "${env:ProgramFiles(x86)}\PerformanceTest\PerformanceTest64.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    $found = Get-ChildItem "$env:ProgramFiles" -Filter 'PerformanceTest*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    return $found.FullName
}

try {
    Write-Host "Result directory: $OutDir"
    Write-Host "UTC start: $((Get-Date).ToUniversalTime().ToString('o'))"

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $memory = Get-CimInstance Win32_PhysicalMemory
    @{
        OS = $os | Select-Object Caption, Version, BuildNumber, OSArchitecture
        Computer = $computer | Select-Object Manufacturer, Model, TotalPhysicalMemory, NumberOfLogicalProcessors
        CPU = $cpu | Select-Object Manufacturer, Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed
        DIMMs = $memory | Select-Object Manufacturer, PartNumber, Capacity, Speed, ConfiguredClockSpeed, BankLabel, DeviceLocator
        PowerShell = $PSVersionTable
    } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $OutDir "system-info.json")
    systeminfo.exe | Set-Content -Encoding UTF8 (Join-Path $OutDir "system-info.txt")

    $osArch = $os.OSArchitecture
    $isArm64 = $osArch -match 'ARM64'
    $isX64 = $osArch -match '64-bit' -and -not $isArm64

    # Vendor-neutral STREAM on native Windows x64, built with GCC/OpenMP from MSYS2.
    if ($isX64) {
        $MsysRoot = "C:\msys64"
        $Gcc = Join-Path $MsysRoot "ucrt64\bin\gcc.exe"
        if (-not (Test-Path $Gcc) -and $InstallDependencies) {
            if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
                throw "WinGet is required for automatic MSYS2 installation."
            }
            winget install --exact --id MSYS2.MSYS2 --accept-package-agreements --accept-source-agreements
            $Bash = Join-Path $MsysRoot "usr\bin\bash.exe"
            if (-not (Test-Path $Bash)) { throw "MSYS2 installation was not found at $MsysRoot." }
            & $Bash -lc "pacman -Sy --needed --noconfirm mingw-w64-ucrt-x86_64-gcc"
        }
        if (Test-Path $Gcc) {
            $env:Path = "$(Join-Path $MsysRoot 'ucrt64\bin');$env:Path"
            $StreamSource = Join-Path $ToolsDir "stream.c"
            $StreamUrl = "https://raw.githubusercontent.com/jeffhammond/STREAM/$StreamCommit/stream.c"
            Invoke-WebRequest -UseBasicParsing -Uri $StreamUrl -OutFile $StreamSource
            Get-FileHash $StreamSource -Algorithm SHA256 | Format-List | Out-File (Join-Path $ToolsDir "stream.c.sha256.txt")
            $StreamExe = Join-Path $ToolsDir "stream-gcc.exe"
            & $Gcc -O3 -march=native -fopenmp "-DSTREAM_ARRAY_SIZE=$StreamArraySize" "-DNTIMES=$NTimes" $StreamSource -o $StreamExe
            if ($LASTEXITCODE -ne 0) { throw "STREAM compilation failed with exit code $LASTEXITCODE." }
            $env:OMP_NUM_THREADS = if ($env:OMP_NUM_THREADS) { $env:OMP_NUM_THREADS } else { [string]$computer.NumberOfLogicalProcessors }
            $env:OMP_PROC_BIND = if ($env:OMP_PROC_BIND) { $env:OMP_PROC_BIND } else { "spread" }
            $env:OMP_PLACES = if ($env:OMP_PLACES) { $env:OMP_PLACES } else { "threads" }
            & $StreamExe 2>&1 | Tee-Object -FilePath (Join-Path $OutDir "stream.txt")
        } else {
            Write-Warning "STREAM skipped: MSYS2 GCC not found. Re-run with -InstallDependencies."
        }
    } else {
        Write-Warning "Native Windows ARM64 STREAM is not auto-built by this script. Use PassMark below, or compile the same source with a native ARM64 OpenMP toolchain."
    }

    # Intel-only MLC. It is intentionally separate from the vendor-neutral result.
    $MlcExe = (Get-Command mlc.exe -ErrorAction SilentlyContinue).Source
    if (-not $MlcExe) { $MlcExe = (Get-Command mlc -ErrorAction SilentlyContinue).Source }
    if ($InstallMlc) {
        if (-not $AcceptIntelLicense) { throw "-InstallMlc requires -AcceptIntelLicense." }
        $MlcArchive = Join-Path $ToolsDir "mlc_v3.12.tgz"
        Invoke-WebRequest -UseBasicParsing -Uri "https://downloadmirror.intel.com/866182/mlc_v3.12.tgz" -OutFile $MlcArchive
        $Expected = "4B8F7685D71998DD5D445432AB40C2115158462BFCD359113AE551A84E250C50"
        $Actual = (Get-FileHash $MlcArchive -Algorithm SHA256).Hash
        if ($Actual -ne $Expected) { throw "Intel MLC checksum mismatch. Expected $Expected, got $Actual." }
        $MlcDir = Join-Path $ToolsDir "mlc_v3.12"
        New-Item -ItemType Directory -Force -Path $MlcDir | Out-Null
        tar.exe -xzf $MlcArchive -C $MlcDir
        $MlcExe = (Get-ChildItem $MlcDir -Filter mlc.exe -Recurse | Select-Object -First 1).FullName
    }
    if (-not $SkipMlc -and $cpu.Manufacturer -match 'Intel' -and $MlcExe) {
        if (-not (Test-IsAdministrator)) { Write-Warning "Run PowerShell as Administrator for complete MLC access." }
        foreach ($test in @('max_bandwidth','peak_injection_bandwidth','loaded_latency','idle_latency')) {
            & $MlcExe "--$test" 2>&1 | Tee-Object -FilePath (Join-Path $OutDir "mlc-$test.txt")
        }
    } elseif (-not $SkipMlc -and $cpu.Manufacturer -match 'Intel') {
        Write-Warning "Intel CPU detected but MLC was not found. Add -InstallMlc -AcceptIntelLicense."
    }

    # PassMark: convenient third-tier benchmark for Windows x64/ARM64 and cross-OS comparison.
    # Installation is opened interactively; after installation, rerun this script to automate ME_ALL and CSV/text export.
    $PtExe = Find-PerformanceTest
    if (-not $PtExe -and $InstallPassMark) {
        $PtUrl = if ($isArm64) {
            "https://www.passmark.com/downloads/PerformanceTest_Windows_ARM.exe"
        } else {
            "https://www.passmark.com/downloads/PerformanceTest_Windows_x86-64.exe"
        }
        $Installer = Join-Path $ToolsDir "PerformanceTest-installer.exe"
        Invoke-WebRequest -UseBasicParsing -Uri $PtUrl -OutFile $Installer
        Write-Host "Opening the official PassMark installer. Rerun this script afterward to execute the memory suite."
        Start-Process $Installer
    } elseif ($PtExe) {
        $PtScript = Join-Path $ToolsDir "passmark-memory.ptscript"
        $CsvPath = (Join-Path $OutDir "passmark-memory.csv").Replace('\','\\')
        $TxtPath = (Join-Path $OutDir "passmark-memory.txt").Replace('\','\\')
        @"
SUPPRESSWARNINGS ON
SETITERATIONS 3
CLEARRESULTS
RUN ME_ALL
EXPORTCSV "$CsvPath"
EXPORTTEXT "$TxtPath"
EXIT
"@ | Set-Content -Encoding ASCII $PtScript
        & $PtExe /NO3D /s $PtScript /i
    }

    Write-Host "UTC finish: $((Get-Date).ToUniversalTime().ToString('o'))"
    Write-Host "Saved results: $OutDir"
}
finally {
    Stop-Transcript | Out-Null
}
