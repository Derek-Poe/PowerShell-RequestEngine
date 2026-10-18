Set-StrictMode -Version Latest

function Start-RequestEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Handler,
        [ValidateRange(1024, 65535)][int]$Port = 8088,
        [ValidateRange(1, 32)][int]$Workers = 8,
        [ValidateRange(0, 1024)][int]$QueueCapacity = 16,
        [ValidateRange(50, 60000)][int]$RequestTimeoutMilliseconds = 2000,
        [ValidateRange(128, 1048576)][int]$MaxResponseBytes = 16384
    )
    $listener = [System.Net.HttpListener]::new()
    $prefix = 'http://127.0.0.1:{0}/' -f $Port
    $listener.Prefixes.Add($prefix)
    $listener.IgnoreWriteExceptions = $true
    $stop = [System.Threading.CancellationTokenSource]::new()
    $cancel = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $state = [hashtable]::Synchronized(@{ Snapshot = $null; Failure = $null })
    $settings = @{ Workers = $Workers; QueueCapacity = $QueueCapacity
        TimeoutMs = $RequestTimeoutMilliseconds; MaxResponseBytes = $MaxResponseBytes }
    $dispatcher = $null
    $runspace = $null
    try {
        $listener.Start()
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $dispatcher = [powershell]::Create()
        $dispatcher.Runspace = $runspace
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Private/Dispatcher.ps1'))
        $null = $dispatcher.AddScript($source).AddArgument($listener).AddArgument($Handler.ToString()).
            AddArgument($settings).AddArgument($state).AddArgument($stop).AddArgument($cancel)
        $async = $dispatcher.BeginInvoke()
        $engine = [pscustomobject]@{ PSTypeName = 'DerekPoe.RequestEngine'; Uri = $prefix
            Dispatcher = $dispatcher; Runspace = $runspace; Async = $async
            StopSource = $stop; CancelQueue = $cancel; State = $state; Cleaned = $false }
        $startup = [Diagnostics.Stopwatch]::StartNew()
        while ($null -eq $state.Snapshot -and -not $async.IsCompleted -and $startup.ElapsedMilliseconds -lt 5000) {
            Start-Sleep -Milliseconds 5
        }
        if ($null -eq $state.Snapshot) { throw 'Request engine dispatcher failed to start.' }
        return $engine
    } catch {
        $stop.Cancel()
        $listener.Close()
        if ($dispatcher) { $dispatcher.Dispose() }
        if ($runspace) { $runspace.Dispose() }
        $stop.Dispose()
        throw
    }
}

function Get-RequestEngineState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Engine)
    # Return detached records, never the mutable dispatcher state or HTTP contexts.
    $snapshot = $Engine.State.Snapshot
    if ($null -eq $snapshot) { return $null }
    $copy = [ordered]@{}
    foreach ($property in $snapshot.PSObject.Properties) {
        if ($property.Name -eq 'Requests') {
            $copy.Requests = @($property.Value | ForEach-Object {
                [pscustomobject]@{ Id = $_.Id; Path = $_.Path; State = $_.State }
            })
        } else { $copy[$property.Name] = $property.Value }
    }
    [pscustomobject]$copy
}

function Stop-RequestEngineRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Engine, [Parameter(Mandatory)][guid]$RequestId)
    if ($Engine.Cleaned) { return }
    $Engine.CancelQueue.Enqueue($RequestId.ToString())
}

function Stop-RequestEngine {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Engine,
        [ValidateRange(0, 60000)][int]$WaitMilliseconds = 5000)
    if (-not $Engine.Cleaned) {
        $Engine.StopSource.Cancel()
        $finished = $Engine.Async.IsCompleted
        if (-not $finished -and $WaitMilliseconds -gt 0) {
            $finished = $Engine.Async.AsyncWaitHandle.WaitOne($WaitMilliseconds)
        }
        if ($finished) {
            try { $null = $Engine.Dispatcher.EndInvoke($Engine.Async) }
            catch { $Engine.State.Failure = 'Dispatcher terminated unexpectedly.' }
            finally {
                $Engine.Dispatcher.Dispose()
                $Engine.Runspace.Dispose()
                $Engine.StopSource.Dispose()
                $Engine.Cleaned = $true
            }
        }
    }
    # False Stopped means a trusted handler has not cooperated with cancellation.
    # Its dispatcher still owns the runspace; call Stop again to finish disposal.
    Get-RequestEngineState -Engine $Engine
}

Export-ModuleMember -Function Start-RequestEngine, Get-RequestEngineState, Stop-RequestEngineRequest, Stop-RequestEngine
