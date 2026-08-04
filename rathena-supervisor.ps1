[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerRoot,
    [int]$LoginPort = 6900,
    [int]$CharPort = 6121,
    [int]$MapPort = 5121,
    [int]$WebPort = 8888,
    [string]$EnableWeb = "true",
    [string]$AutoRestart = "true",
    [int]$RestartLimit = 3,
    [int]$RestartBackoffSeconds = 3,
    [int]$ShutdownTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$script:stopping = $false
$script:exitCode = 0
$script:runtime = @{}
$script:restartCounts = @{}

function ConvertTo-Switch {
    param([string]$Value)
    return @("1", "true", "yes", "on", "enabled") -contains $Value.Trim().ToLowerInvariant()
}

$webEnabled = ConvertTo-Switch $EnableWeb
$restartEnabled = ConvertTo-Switch $AutoRestart
$RestartLimit = [Math]::Max(0, [Math]::Min(10, $RestartLimit))
$RestartBackoffSeconds = [Math]::Max(1, [Math]::Min(60, $RestartBackoffSeconds))
$ShutdownTimeoutSeconds = [Math]::Max(5, [Math]::Min(120, $ShutdownTimeoutSeconds))
$ServerRoot = [IO.Path]::GetFullPath($ServerRoot)

& (Join-Path $PSScriptRoot "amp-config-link.ps1") -ServerRoot $ServerRoot

$services = [ordered]@{
    login = [pscustomobject]@{ Executable = "login-server.exe"; Port = $LoginPort; GracefulCommand = "server:shutdown" }
    char = [pscustomobject]@{ Executable = "char-server.exe"; Port = $CharPort; GracefulCommand = "server:shutdown" }
    web = [pscustomobject]@{ Executable = "web-server.exe"; Port = $WebPort; GracefulCommand = "" }
    map = [pscustomobject]@{ Executable = "map-server.exe"; Port = $MapPort; GracefulCommand = "server:shutdown" }
}

if (-not $webEnabled) {
    $services.Remove("web")
}

if (-not (Test-Path -LiteralPath $ServerRoot -PathType Container)) {
    throw "rAthena server folder does not exist: $ServerRoot"
}

foreach ($entry in $services.GetEnumerator()) {
    $path = Join-Path $ServerRoot $entry.Value.Executable
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required rAthena executable is missing: $path"
    }
    $script:restartCounts[$entry.Key] = 0
}

function Test-TcpPort {
    param([int]$Port, [int]$TimeoutMilliseconds = 500)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync("127.0.0.1", $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Wait-TcpPort {
    param([int]$Port, [int]$TimeoutSeconds = 45, [string]$ServiceName = "")
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
            Drain-RathenaOutput -Name $ServiceName
            $state = $script:runtime[$ServiceName]
            if ($null -ne $state -and $state.Process.HasExited) {
                Drain-RathenaOutput -Name $ServiceName
                return $false
            }
        }
        if (Test-TcpPort -Port $Port) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Start-RathenaService {
    param([Parameter(Mandatory = $true)][string]$Name)

    $definition = $services[$Name]
    if ($null -eq $definition) {
        throw "Unknown rAthena service: $Name"
    }
    $current = $script:runtime[$Name]
    if ($null -ne $current -and -not $current.Process.HasExited) {
        return
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $ServerRoot $definition.Executable
    $startInfo.WorkingDirectory = $ServerRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start rAthena service: $Name"
    }
    $script:runtime[$Name] = [pscustomobject]@{
        Process = $process
        StdoutTask = $process.StandardOutput.ReadLineAsync()
        StderrTask = $process.StandardError.ReadLineAsync()
        StartedAt = [DateTime]::UtcNow
    }
    [Console]::WriteLine(("[supervisor] STARTED service={0} pid={1}" -f $Name, $process.Id))
}

function Drain-RathenaOutput {
    param([Parameter(Mandatory = $true)][string]$Name)

    $state = $script:runtime[$Name]
    if ($null -eq $state) {
        return
    }
    foreach ($stream in @(
        [pscustomobject]@{ TaskProperty = "StdoutTask"; Reader = $state.Process.StandardOutput; Prefix = $Name },
        [pscustomobject]@{ TaskProperty = "StderrTask"; Reader = $state.Process.StandardError; Prefix = "${Name}:stderr" }
    )) {
        $task = $state.($stream.TaskProperty)
        while ($null -ne $task -and $task.IsCompleted) {
            try {
                $line = $task.GetAwaiter().GetResult()
            }
            catch {
                [Console]::WriteLine(("[{0}] OUTPUT_READ_FAILED {1}" -f $stream.Prefix, $_.Exception.Message))
                $line = $null
            }
            if ($null -eq $line) {
                $state.($stream.TaskProperty) = $null
                break
            }
            [Console]::WriteLine(("[{0}] {1}" -f $stream.Prefix, $line))
            $task = $stream.Reader.ReadLineAsync()
            $state.($stream.TaskProperty) = $task
        }
    }
}

function Send-RathenaCommand {
    param([string]$Name, [string]$Command)
    $state = $script:runtime[$Name]
    if ($null -eq $state -or $state.Process.HasExited) {
        return $false
    }
    try {
        $state.Process.StandardInput.WriteLine($Command)
        $state.Process.StandardInput.Flush()
        return $true
    }
    catch {
        [Console]::WriteLine(("[supervisor] COMMAND_FAILED service={0} error={1}" -f $Name, $_.Exception.Message))
        return $false
    }
}

function Stop-RathenaService {
    param([string]$Name, [int]$TimeoutSeconds = 10)
    $state = $script:runtime[$Name]
    if ($null -eq $state -or $state.Process.HasExited) {
        return
    }
    $definition = $services[$Name]
    if (-not [string]::IsNullOrWhiteSpace($definition.GracefulCommand)) {
        [void](Send-RathenaCommand -Name $Name -Command $definition.GracefulCommand)
    }
    elseif ($state.Process.CloseMainWindow()) {
        [Console]::WriteLine(("[supervisor] CLOSE_REQUESTED service={0}" -f $Name))
    }
    if (-not $state.Process.WaitForExit($TimeoutSeconds * 1000)) {
        [Console]::WriteLine(("[supervisor] FORCE_STOP service={0} pid={1}" -f $Name, $state.Process.Id))
        $state.Process.Kill()
        [void]$state.Process.WaitForExit(5000)
    }
    Drain-RathenaOutput -Name $Name
}

function Stop-AllRathenaServices {
    if ($script:stopping) {
        return
    }
    $script:stopping = $true
    [Console]::WriteLine("[supervisor] STOPPING")
    foreach ($name in @("map", "char", "login")) {
        if ($services.Contains($name)) {
            [void](Send-RathenaCommand -Name $name -Command $services[$name].GracefulCommand)
        }
    }
    if ($services.Contains("web")) {
        $webState = $script:runtime["web"]
        if ($null -ne $webState -and -not $webState.Process.HasExited) {
            [void]$webState.Process.CloseMainWindow()
        }
    }
    $shutdownDeadline = [DateTime]::UtcNow.AddSeconds($ShutdownTimeoutSeconds)
    do {
        $remaining = 0
        foreach ($entry in @($script:runtime.GetEnumerator())) {
            Drain-RathenaOutput -Name $entry.Key
            if ($null -ne $entry.Value -and -not $entry.Value.Process.HasExited) {
                $remaining++
            }
        }
        if ($remaining -gt 0) {
            Start-Sleep -Milliseconds 200
        }
    } while ($remaining -gt 0 -and [DateTime]::UtcNow -lt $shutdownDeadline)
    foreach ($entry in @($script:runtime.GetEnumerator())) {
        $state = $entry.Value
        if ($null -ne $state -and -not $state.Process.HasExited) {
            [Console]::WriteLine(("[supervisor] FORCE_STOP service={0} pid={1}" -f $entry.Key, $state.Process.Id))
            $state.Process.Kill()
            [void]$state.Process.WaitForExit(5000)
        }
    }
    foreach ($entry in @($script:runtime.GetEnumerator())) {
        $state = $entry.Value
        Drain-RathenaOutput -Name $entry.Key
        if ($null -ne $state) {
            Drain-RathenaOutput -Name $entry.Key
            $state.Process.Dispose()
        }
    }
    [Console]::WriteLine("[supervisor] STOPPED")
}

function Write-RathenaStatus {
    foreach ($entry in $services.GetEnumerator()) {
        $state = $script:runtime[$entry.Key]
        $running = $null -ne $state -and -not $state.Process.HasExited
        $pidText = if ($running) { [string]$state.Process.Id } else { "-" }
        $portReady = Test-TcpPort -Port $entry.Value.Port -TimeoutMilliseconds 200
        [Console]::WriteLine(("[supervisor] STATUS service={0} running={1} pid={2} port={3} ready={4}" -f $entry.Key, $running.ToString().ToLowerInvariant(), $pidText, $entry.Value.Port, $portReady.ToString().ToLowerInvariant()))
    }
}

function Handle-SupervisorCommand {
    param([string]$Line)
    $trimmed = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $true
    }
    if ($trimmed -in @("ampstop", "shutdown", "exit", "quit")) {
        return $false
    }
    if ($trimmed -eq "status") {
        Write-RathenaStatus
        return $true
    }
    if ($trimmed -match '^send\s+(login|char|map)\s+(.+)$') {
        [void](Send-RathenaCommand -Name $Matches[1] -Command $Matches[2])
        return $true
    }
    if ($trimmed -match '^restart\s+(login|char|map|web)$') {
        $name = $Matches[1]
        if (-not $services.Contains($name)) {
            [Console]::WriteLine(("[supervisor] SERVICE_DISABLED service={0}" -f $name))
            return $true
        }
        Stop-RathenaService -Name $name -TimeoutSeconds 10
        Start-RathenaService -Name $name
        return $true
    }
    [void](Send-RathenaCommand -Name "map" -Command $trimmed)
    return $true
}

try {
    [Console]::WriteLine(("[supervisor] ROOT {0}" -f $ServerRoot))
    Start-RathenaService -Name "login"
    if (-not (Wait-TcpPort -Port $LoginPort -TimeoutSeconds 45 -ServiceName "login")) {
        throw "login-server did not open TCP port $LoginPort"
    }
    Start-RathenaService -Name "char"
    if (-not (Wait-TcpPort -Port $CharPort -TimeoutSeconds 45 -ServiceName "char")) {
        throw "char-server did not open TCP port $CharPort"
    }
    if ($webEnabled) {
        Start-RathenaService -Name "web"
    }
    Start-RathenaService -Name "map"

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(600)
    do {
        $allReady = $true
        foreach ($entry in $services.GetEnumerator()) {
            Drain-RathenaOutput -Name $entry.Key
            $state = $script:runtime[$entry.Key]
            if ($null -ne $state -and $state.Process.HasExited) {
                throw "$($entry.Key) service exited before becoming ready"
            }
            if (-not (Test-TcpPort -Port $entry.Value.Port)) {
                $allReady = $false
                break
            }
        }
        if (-not $allReady) {
            Start-Sleep -Milliseconds 500
        }
    } while (-not $allReady -and [DateTime]::UtcNow -lt $readyDeadline)
    if (-not $allReady) {
        throw "Not all enabled rAthena services became ready within 600 seconds"
    }
    $webStatus = if ($webEnabled) { [string]$WebPort } else { "disabled" }
    [Console]::WriteLine(("[supervisor] READY login={0} char={1} map={2} web={3}" -f $LoginPort, $CharPort, $MapPort, $webStatus))

    $inputClosed = $false
    $readTask = [Console]::In.ReadLineAsync()
    $keepRunning = $true
    while ($keepRunning -and -not $script:stopping) {
        foreach ($entry in @($services.GetEnumerator())) {
            $name = $entry.Key
            Drain-RathenaOutput -Name $name
            $state = $script:runtime[$name]
            if ($null -eq $state -or -not $state.Process.HasExited) {
                continue
            }
            $exitCode = $state.Process.ExitCode
            $lifetime = ([DateTime]::UtcNow - $state.StartedAt).TotalSeconds
            [Console]::WriteLine(("[supervisor] EXITED service={0} code={1} lifetime_seconds={2:N1}" -f $name, $exitCode, $lifetime))
            $state.Process.Dispose()
            $script:runtime.Remove($name)
            if (-not $restartEnabled) {
                throw "rAthena service exited and automatic restart is disabled: $name"
            }
            if ($lifetime -ge 300) {
                $script:restartCounts[$name] = 0
            }
            $attempt = [int]$script:restartCounts[$name] + 1
            $script:restartCounts[$name] = $attempt
            if ($attempt -gt $RestartLimit) {
                throw "rAthena service exceeded restart limit: $name"
            }
            $delay = [Math]::Min(60, $RestartBackoffSeconds * $attempt)
            [Console]::WriteLine(("[supervisor] RESTARTING service={0} attempt={1}/{2} delay_seconds={3}" -f $name, $attempt, $RestartLimit, $delay))
            Start-Sleep -Seconds $delay
            Start-RathenaService -Name $name
        }

        if (-not $inputClosed -and $readTask.IsCompleted) {
            try {
                $line = $readTask.GetAwaiter().GetResult()
            }
            catch {
                $line = $null
            }
            if ($null -eq $line) {
                $inputClosed = $true
            }
            else {
                $keepRunning = Handle-SupervisorCommand -Line $line
                $readTask = [Console]::In.ReadLineAsync()
            }
        }
        Start-Sleep -Milliseconds 200
    }
}
catch {
    [Console]::WriteLine(("[supervisor] FATAL type={0} message={1}" -f $_.Exception.GetType().FullName, $_.Exception.Message))
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        [Console]::WriteLine(("[supervisor] FATAL_STACK {0}" -f ($_.ScriptStackTrace -replace "[\r\n]+", " | ")))
    }
    $script:exitCode = 1
}
finally {
    Stop-AllRathenaServices
}

if ($script:exitCode -eq 1) {
    exit 1
}
exit 0
