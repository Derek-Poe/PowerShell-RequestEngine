param($Listener, [string]$HandlerSource, $Settings, $SharedState, $StopSource, $CancelQueue)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$clock = [Diagnostics.Stopwatch]::StartNew()
$active = [Collections.Generic.List[object]]::new()
$queue = [Collections.Generic.List[object]]::new()
$counts = @{ Received = 0; Accepted = 0; Rejected = 0; Completed = 0
    Failed = 0; TimedOut = 0; Cancelled = 0; Started = 0; Disposed = 0
    PeakActive = 0; PeakQueued = 0; Responses = 0; WriteFailures = 0 }
$stopping = $false
$faulted = $false

function Publish-State {
    $fields = [ordered]@{ Stopping = $stopping; Stopped = ($stopping -and $active.Count -eq 0 -and $queue.Count -eq 0)
        Faulted = $faulted; Active = $active.Count; Queued = $queue.Count
        WorkerLimit = $Settings.Workers; QueueLimit = $Settings.QueueCapacity }
    foreach ($key in $counts.Keys) { $fields[$key] = $counts[$key] }
    $fields.Requests = @(@($active.ToArray()) + @($queue.ToArray()) | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Path = $_.Request.Path; State = $_.State }
    })
    $SharedState.Snapshot = [pscustomobject]$fields
}

function Send-Response($Job, [int]$Status, [string]$Body, [string]$ContentType = 'application/json; charset=utf-8') {
    if ($Job.Responded) { return }
    $Job.Responded = $true
    $counts.Responses++
    try {
        $response = $Job.Context.Response
        $response.StatusCode = $Status
        $response.ContentType = $ContentType
        $response.Headers['X-Request-Id'] = $Job.Id
        $response.Headers['Cache-Control'] = 'no-store'
        if ($Status -eq 503) { $response.Headers['Retry-After'] = '1' }
        if ($Status -eq 405) { $response.Headers['Allow'] = 'GET' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $response.ContentLength64 = $bytes.Length
        # HttpListener owns the asynchronous send after Close; a slow reader does
        # not hold the dispatcher or an execution slot. Bodies are size-bounded.
        $response.Close($bytes, $false)
    } catch {
        $counts.WriteFailures++
        try { $Job.Context.Response.Abort() } catch { }
    } finally { $Job.Context = $null }
}

function Start-Work($Job) {
    if ($clock.ElapsedMilliseconds -ge $Job.Deadline) {
        $counts.TimedOut++
        Send-Response $Job 504 '{"error":"deadline_exceeded"}'
        $Job.Cancellation.Dispose()
        return
    }
    $space = $null
    $shell = $null
    try {
        # A fresh session avoids leaking variables/functions between pooled jobs.
        # The original used RunspacePool; explicit ownership here favors isolation.
        $space = [runspacefactory]::CreateRunspace([Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
        $space.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $space
        $wrapper = @'
param($Source, $Request, $CancellationToken)
$ErrorActionPreference = 'Stop'
& ([scriptblock]::Create($Source)) $Request $CancellationToken
'@
        $null = $shell.AddScript($wrapper).AddArgument($HandlerSource).AddArgument($Job.Request).AddArgument($Job.Cancellation.Token)
        $Job.Runspace = $space
        $Job.Shell = $shell
        $Job.Async = $shell.BeginInvoke()
        $Job.State = 'Running'
        $active.Add($Job)
        $counts.Started++
        $counts.PeakActive = [Math]::Max($counts.PeakActive, $active.Count)
    } catch {
        if ($shell) { $shell.Dispose() }
        if ($space) { $space.Dispose() }
        $Job.Cancellation.Dispose()
        $counts.Failed++
        Send-Response $Job 500 '{"error":"worker_start_failed"}'
    }
}

function Cancel-Work($Job, [string]$Reason, [int]$Status) {
    if ($Job.Responded) { return }
    if ($Reason -eq 'deadline_exceeded') { $counts.TimedOut++ } else { $counts.Cancelled++ }
    Send-Response $Job $Status ('{"error":"' + $Reason + '"}')
    $Job.Cancellation.Cancel()
    $Job.State = 'Stopping'
    try { $Job.StopAsync = $Job.Shell.BeginStop($null, $null) } catch { }
    # Keep its active slot until EndInvoke and disposal have completed.
}

function Reap-Work {
    for ($index = $active.Count - 1; $index -ge 0; $index--) {
        $job = $active[$index]
        if (-not $job.Async.IsCompleted) { continue }
        try {
            if (-not $job.Responded -and $clock.ElapsedMilliseconds -ge $job.Deadline) {
                $counts.TimedOut++
                Send-Response $job 504 '{"error":"deadline_exceeded"}'
            }
            if ($null -ne $job.StopAsync) { $job.Shell.EndStop($job.StopAsync) }
            $result = $job.Shell.EndInvoke($job.Async)
            if (-not $job.Responded) {
                if ($job.Shell.HadErrors -or $result.Count -ne 1) { throw 'Handler must return exactly one response.' }
                $reply = $result[0]
                $status = [int]$reply.StatusCode
                $body = [string]$reply.Body
                $contentType = [string]$reply.ContentType
                if ($status -lt 200 -or $status -gt 599 -or $contentType.Length -eq 0 -or
                    $contentType.Length -gt 128 -or $contentType -match '[\r\n]' -or
                    [Text.Encoding]::UTF8.GetByteCount($body) -gt $Settings.MaxResponseBytes) {
                    throw 'Invalid handler response.'
                }
                if ($status -eq 204 -or $status -eq 304) { $body = '' }
                Send-Response $job $status $body $contentType
                $counts.Completed++
            }
        } catch {
            if (-not $job.Responded) {
                $counts.Failed++
                Send-Response $job 500 '{"error":"handler_failed"}'
            }
        } finally {
            $job.Shell.Dispose()
            $job.Runspace.Dispose()
            $job.Cancellation.Dispose()
            $active.RemoveAt($index)
            $counts.Disposed++
        }
    }
}

function New-Job($Context) {
    $id = [guid]::NewGuid().ToString()
    # Handler receives fresh request data and a token, never HttpListenerContext,
    # a response stream, shared database connection, or another request's state.
    $request = [pscustomobject]@{ Id = $id; Method = $Context.Request.HttpMethod
        Path = $Context.Request.Url.AbsolutePath; Query = $Context.Request.Url.Query }
    [pscustomobject]@{ Id = $id; Context = $Context; Request = $request
        Deadline = $clock.ElapsedMilliseconds + $Settings.TimeoutMs
        State = 'Queued'; Responded = $false; Shell = $null; Runspace = $null
        Async = $null; StopAsync = $null; Cancellation = [Threading.CancellationTokenSource]::new() }
}

try {
    $accept = $Listener.GetContextAsync()
    Publish-State
    while ($true) {
        Reap-Work
        if ($StopSource.IsCancellationRequested -and -not $stopping) {
            $stopping = $true
            # Stop admitting first; existing contexts get explicit cancellation.
            foreach ($job in $queue.ToArray()) {
                $counts.Cancelled++
                Send-Response $job 503 '{"error":"server_stopping"}'
                $job.Cancellation.Dispose()
            }
            $queue.Clear()
            foreach ($job in $active.ToArray()) { Cancel-Work $job 'server_stopping' 503 }
        }

        $cancelId = $null
        while ($CancelQueue.TryDequeue([ref]$cancelId)) {
            foreach ($job in $active.ToArray()) {
                if ($job.Id -eq $cancelId) { Cancel-Work $job 'request_cancelled' 503 }
            }
            for ($index = $queue.Count - 1; $index -ge 0; $index--) {
                $job = $queue[$index]
                if ($job.Id -eq $cancelId) {
                    $counts.Cancelled++
                    Send-Response $job 503 '{"error":"request_cancelled"}'
                    $job.Cancellation.Dispose()
                    $queue.RemoveAt($index)
                }
            }
        }

        foreach ($job in $active.ToArray()) {
            if ($clock.ElapsedMilliseconds -ge $job.Deadline) { Cancel-Work $job 'deadline_exceeded' 504 }
        }
        for ($index = $queue.Count - 1; $index -ge 0; $index--) {
            $job = $queue[$index]
            if ($clock.ElapsedMilliseconds -ge $job.Deadline) {
                $counts.TimedOut++
                Send-Response $job 504 '{"error":"deadline_exceeded"}'
                $job.Cancellation.Dispose()
                $queue.RemoveAt($index)
            }
        }

        if (-not $stopping) {
            while ($active.Count -lt $Settings.Workers -and $queue.Count -gt 0) {
                $job = $queue[0]
                $queue.RemoveAt(0)
                Start-Work $job
            }
            # Process a bounded accept batch, then revisit deadlines/completions.
            for ($batch = 0; $batch -lt 16 -and $accept.IsCompleted; $batch++) {
                $context = $accept.GetAwaiter().GetResult()
                $accept = $Listener.GetContextAsync()
                $counts.Received++
                $job = New-Job $context
                if ($job.Request.Method -ne 'GET' -or $context.Request.HasEntityBody) {
                    $counts.Rejected++
                    Send-Response $job 405 '{"error":"only_bodyless_get_supported"}'
                    $job.Cancellation.Dispose()
                } elseif ($job.Request.Path.Length + $job.Request.Query.Length -gt 2048) {
                    $counts.Rejected++
                    Send-Response $job 414 '{"error":"request_target_too_long"}'
                    $job.Cancellation.Dispose()
                } elseif ($active.Count -lt $Settings.Workers -and $queue.Count -eq 0) {
                    $counts.Accepted++
                    Start-Work $job
                } elseif ($queue.Count -lt $Settings.QueueCapacity) {
                    $counts.Accepted++
                    $queue.Add($job)
                    $counts.PeakQueued = [Math]::Max($counts.PeakQueued, $queue.Count)
                } else {
                    $counts.Rejected++
                    Send-Response $job 503 '{"error":"capacity_exceeded"}'
                    $job.Cancellation.Dispose()
                }
            }
        }
        Publish-State
        if ($stopping -and $active.Count -eq 0) { break }
        # Do not spin after shutdown is requested while a native call winds down.
        Start-Sleep -Milliseconds 5
    }
} catch {
    $faulted = $true
    $stopping = $true
    $SharedState.Failure = 'Dispatcher failed; inspect trusted handler and listener configuration.'
    foreach ($job in $queue.ToArray()) {
        $counts.Cancelled++
        Send-Response $job 503 '{"error":"server_stopping"}'
        $job.Cancellation.Dispose()
    }
    $queue.Clear()
    foreach ($job in $active.ToArray()) { Cancel-Work $job 'server_stopping' 503 }
    while ($active.Count -gt 0) { Reap-Work; Publish-State; Start-Sleep -Milliseconds 5 }
} finally {
    # Closes the outstanding accept and any transport-owned asynchronous sends.
    $Listener.Close()
    $stopping = $true
    Publish-State
}
