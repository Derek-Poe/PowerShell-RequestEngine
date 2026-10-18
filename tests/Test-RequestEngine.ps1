$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RequestEngine.psd1') -Force
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::DefaultConnectionLimit = 64
$transport = [Net.Http.HttpClientHandler]::new()
$transport.UseProxy = $false
$client = [Net.Http.HttpClient]::new($transport)
$client.Timeout = [TimeSpan]::FromSeconds(15)
$engines = [Collections.Generic.List[object]]::new()
$script:checks = 0

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
    $script:checks++
}
function Get-FreePort {
    $socket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $socket.Start()
    try { $socket.LocalEndpoint.Port } finally { $socket.Stop() }
}
function Start-TestEngine([scriptblock]$Handler, [int]$Workers = 2, [int]$QueueCapacity = 2, [int]$Timeout = 3000) {
    $engine = Start-RequestEngine -Handler $Handler -Port (Get-FreePort) -Workers $Workers -QueueCapacity $QueueCapacity -RequestTimeoutMilliseconds $Timeout
    $engines.Add($engine)
    $engine
}
function Wait-State($Engine, [scriptblock]$Predicate, [int]$Timeout = 4000) {
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        $state = Get-RequestEngineState $Engine
        if ($state.Faulted) { throw 'Dispatcher faulted during test.' }
        if (& $Predicate $state) { return $state }
        Start-Sleep -Milliseconds 5
    } while ($wait.ElapsedMilliseconds -lt $Timeout)
    throw 'Timed out waiting for engine state.'
}
function Read-Reply($Task) {
    $response = $Task.GetAwaiter().GetResult()
    try {
        [pscustomobject]@{ Status = [int]$response.StatusCode
            Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            Id = @($response.Headers.GetValues('X-Request-Id'))[0] }
    } finally { $response.Dispose() }
}
function Stop-AndCheck($Engine) {
    $state = Stop-RequestEngine $Engine
    Assert $state.Stopped 'cooperative shutdown completes'
    Assert ($state.Active -eq 0 -and $state.Queued -eq 0) 'shutdown leaves no jobs'
    Assert ($state.Started -eq $state.Disposed) 'every started worker is disposed'
    Assert (-not $state.Faulted) 'dispatcher did not fault'
    $again = Stop-RequestEngine $Engine
    Assert $again.Stopped 'shutdown is idempotent'
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, ([uri]$Engine.Uri).Port)
    try { $probe.Start(); Assert $true 'listener port is released' } finally { $probe.Stop() }
}

try {
    # Reverse completion order must not cross-wire contexts or EndInvoke handles.
    $engine = Start-TestEngine -Workers 4 -QueueCapacity 4 -Handler {
        param($Request, $CancellationToken)
        $number = [int]$Request.Path.Trim('/')
        Start-Sleep -Milliseconds ((4 - $number) * 80)
        @{ StatusCode = 200; Body = ($Request.Id + ':' + $number); ContentType = 'text/plain' }
    }
    $pending = @(1..4 | ForEach-Object { $client.GetAsync($engine.Uri + $_) })
    for ($i = 0; $i -lt $pending.Count; $i++) {
        $reply = Read-Reply $pending[$i]
        Assert ($reply.Status -eq 200) 'correlated request succeeds'
        Assert ($reply.Body -eq ($reply.Id + ':' + ($i + 1))) 'response belongs to its original context'
    }
    $state = Wait-State $engine { param($s) $s.Active -eq 0 }
    Assert ($state.Started -eq 4 -and $state.Completed -eq 4 -and $state.Responses -eq 4) 'one response and completion per request'
    Stop-AndCheck $engine

    # Saturation rejects excess work immediately, preserving a real queue bound.
    $engine = Start-TestEngine -Workers 1 -QueueCapacity 1 -Handler {
        param($Request, $CancellationToken)
        Start-Sleep -Milliseconds 500
        @{ StatusCode = 200; Body = $Request.Path; ContentType = 'text/plain' }
    }
    $first = $client.GetAsync($engine.Uri + 'active')
    $null = Wait-State $engine { param($s) $s.Active -eq 1 }
    $second = $client.GetAsync($engine.Uri + 'queued')
    $null = Wait-State $engine { param($s) $s.Queued -eq 1 }
    $excess = Read-Reply ($client.GetAsync($engine.Uri + 'excess'))
    Assert ($excess.Status -eq 503 -and $excess.Body -match 'capacity_exceeded') 'saturation returns explicit 503'
    Assert ((Read-Reply $first).Body -eq '/active') 'active context survives saturation'
    Assert ((Read-Reply $second).Body -eq '/queued') 'queued context survives saturation'
    $state = Wait-State $engine { param($s) $s.Active -eq 0 }
    Assert ($state.PeakActive -eq 1 -and $state.PeakQueued -eq 1 -and $state.Rejected -eq 1) 'capacity metrics obey configured bounds'
    Stop-AndCheck $engine

    # Fresh runspaces isolate global variables and definitions, not merely locals.
    $engine = Start-TestEngine -Workers 1 -Handler {
        param($Request, $CancellationToken)
        $leaked = $null -ne (Get-Variable EngineIsolationProbe -Scope Global -ErrorAction SilentlyContinue)
        $functionLeaked = $null -ne (Get-Command EngineIsolationFunction -ErrorAction SilentlyContinue)
        $global:EngineIsolationProbe = $Request.Path
        function global:EngineIsolationFunction { 'private-to-this-request' }
        $hasContext = $null -ne $Request.PSObject.Properties['Context']
        @{ StatusCode = 200; Body = ("$leaked,$functionLeaked,$hasContext," + $Request.Path); ContentType = 'text/plain' }
    }
    foreach ($path in @(1..12 | ForEach-Object { 'request-' + $_ })) {
        $reply = Read-Reply ($client.GetAsync($engine.Uri + $path))
        Assert ($reply.Body -eq ('False,False,False,/' + $path)) 'no pooled globals/functions or HTTP context exposed'
    }
    Stop-AndCheck $engine

    # Terminating errors, nonterminating errors and invalid/oversized results are
    # safe 500 responses; the worker slot remains usable after each failure.
    $engine = Start-TestEngine -Workers 1 -Handler {
        param($Request, $CancellationToken)
        switch ($Request.Path) {
            '/throw' { throw 'SYNTHETIC_PRIVATE_DETAIL' }
            '/error' { Write-Error 'SYNTHETIC_PRIVATE_DETAIL' -ErrorAction Continue }
            '/multiple' { @{ StatusCode = 200; Body = 'extra'; ContentType = 'text/plain' } }
            '/large' { return @{ StatusCode = 200; Body = ('x' * 20000); ContentType = 'text/plain' } }
        }
        @{ StatusCode = 200; Body = 'healthy'; ContentType = 'text/plain' }
    }
    foreach ($path in @('throw', 'error', 'multiple', 'large')) {
        $reply = Read-Reply ($client.GetAsync($engine.Uri + $path))
        Assert ($reply.Status -eq 500) 'handler failure becomes 500'
        Assert ($reply.Body -notmatch 'SYNTHETIC_PRIVATE_DETAIL') 'handler details are not returned'
    }
    Assert ((Read-Reply ($client.GetAsync($engine.Uri + 'healthy'))).Status -eq 200) 'worker capacity recovers after exceptions'
    $post = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $engine.Uri)
    try { Assert ((Read-Reply ($client.SendAsync($post))).Status -eq 405) 'unsupported request method rejected' } finally { $post.Dispose() }
    Stop-AndCheck $engine

    # Deadlines start at admission, including queue time; expired queued work
    # must never start. A blocking .NET call demonstrates cooperative-stop limits.
    $engine = Start-TestEngine -Workers 1 -QueueCapacity 1 -Timeout 250 -Handler {
        param($Request, $CancellationToken)
        [Threading.Thread]::Sleep(1800)
        @{ StatusCode = 200; Body = 'too late'; ContentType = 'text/plain' }
    }
    $first = $client.GetAsync($engine.Uri + 'blocking')
    $null = Wait-State $engine { param($s) $s.Active -eq 1 }
    $second = $client.GetAsync($engine.Uri + 'expires-in-queue')
    Assert ((Read-Reply $first).Status -eq 504) 'running request times out'
    Assert ((Read-Reply $second).Status -eq 504) 'queued request times out'
    $state = Wait-State $engine { param($s) $s.TimedOut -eq 2 }
    Assert ($state.Started -eq 1 -and $state.Active -eq 1 -and $state.TimedOut -eq 2) 'cancelling native call keeps its slot and expired queued work never executes'
    $wait = [Diagnostics.Stopwatch]::StartNew()
    $state = Stop-RequestEngine $engine -WaitMilliseconds 20
    Assert (-not $state.Stopped -and $wait.ElapsedMilliseconds -lt 400) 'bounded stop wait reports remaining cooperative work'
    $null = Wait-State $engine { param($s) $s.Stopped }
    Stop-AndCheck $engine

    # Explicit cancellation is by stable request identity for both queued and
    # active work, not a shared mutable CurrentCon slot.
    $engine = Start-TestEngine -Workers 1 -QueueCapacity 1 -Handler {
        param($Request, $CancellationToken)
        while (-not $CancellationToken.IsCancellationRequested) { Start-Sleep -Milliseconds 10 }
        @{ StatusCode = 200; Body = 'cancelled'; ContentType = 'text/plain' }
    }
    $first = $client.GetAsync($engine.Uri + 'active')
    $null = Wait-State $engine { param($s) $s.Active -eq 1 }
    $second = $client.GetAsync($engine.Uri + 'queued')
    $state = Wait-State $engine { param($s) $s.Queued -eq 1 }
    $queuedId = ($state.Requests | Where-Object Path -eq '/queued').Id
    Stop-RequestEngineRequest $engine $queuedId
    Assert ((Read-Reply $second).Status -eq 503) 'queued cancellation completes its response'
    $activeId = ($state.Requests | Where-Object Path -eq '/active').Id
    Stop-RequestEngineRequest $engine $activeId
    Assert ((Read-Reply $first).Status -eq 503) 'active cancellation completes its response'
    $state = Wait-State $engine { param($s) $s.Active -eq 0 }
    Assert ($state.Cancelled -eq 2 -and $state.Started -eq 1) 'cancelled queued request never runs'
    Stop-AndCheck $engine

    # A client disappearing during handler execution must not leak capacity or
    # prevent another request from receiving its own response.
    $engine = Start-TestEngine -Workers 1 -QueueCapacity 0 -Handler {
        param($Request, $CancellationToken)
        if ($Request.Path -eq '/disconnect') { Start-Sleep -Milliseconds 250 }
        @{ StatusCode = 200; Body = $Request.Path; ContentType = 'text/plain' }
    }
    $socket = [Net.Sockets.TcpClient]::new()
    $socket.Connect('127.0.0.1', ([uri]$engine.Uri).Port)
    $wire = [Text.Encoding]::ASCII.GetBytes("GET /disconnect HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
    $socket.GetStream().Write($wire, 0, $wire.Length)
    $null = Wait-State $engine { param($s) $s.Active -eq 1 }
    $socket.Dispose()
    Assert ((Read-Reply ($client.GetAsync($engine.Uri + 'no-queue'))).Status -eq 503) 'zero-capacity queue rejects while a disconnected client handler still owns its slot'
    $state = Wait-State $engine { param($s) $s.Active -eq 0 }
    Assert ($state.Started -eq $state.Disposed) 'client disconnect does not leak a worker'
    Assert ((Read-Reply ($client.GetAsync($engine.Uri + 'healthy'))).Body -eq '/healthy') 'engine serves requests after a disconnect'
    Stop-AndCheck $engine

    # Burst traffic exercises the count bounds across repeated admission/reaping.
    $engine = Start-TestEngine -Workers 3 -QueueCapacity 4 -Handler {
        param($Request, $CancellationToken)
        Start-Sleep -Milliseconds 30
        @{ StatusCode = 200; Body = ($Request.Id + ':' + $Request.Path); ContentType = 'text/plain' }
    }
    $tasks = @(1..40 | ForEach-Object { $client.GetAsync($engine.Uri + $_) })
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $reply = Read-Reply $tasks[$i]
        Assert ($reply.Status -eq 200 -or $reply.Status -eq 503) 'burst returns a completed or explicitly rejected request'
        if ($reply.Status -eq 200) { Assert ($reply.Body -eq ($reply.Id + ':/' + ($i + 1))) 'burst keeps response/context ownership' }
    }
    $state = Wait-State $engine { param($s) $s.Active -eq 0 -and $s.Queued -eq 0 }
    Assert ($state.PeakActive -le 3 -and $state.PeakQueued -le 4) 'burst never exceeds active or queue bounds'
    Assert ($state.Received -eq 40 -and $state.Responses -eq 40 -and ($state.Completed + $state.Rejected) -eq 40) 'burst accounts for every request exactly once'
    Stop-AndCheck $engine

    # Shutdown cancels active + queued contexts and releases the listener.
    $engine = Start-TestEngine -Workers 1 -QueueCapacity 1 -Handler {
        param($Request, $CancellationToken)
        Start-Sleep -Seconds 10
        @{ StatusCode = 200; Body = 'unexpected'; ContentType = 'text/plain' }
    }
    $first = $client.GetAsync($engine.Uri + 'active')
    $null = Wait-State $engine { param($s) $s.Active -eq 1 }
    $second = $client.GetAsync($engine.Uri + 'queued')
    $null = Wait-State $engine { param($s) $s.Queued -eq 1 }
    $state = Stop-RequestEngine $engine
    Assert ((Read-Reply $first).Status -eq 503) 'shutdown closes active context'
    Assert ((Read-Reply $second).Status -eq 503) 'shutdown closes queued context'
    Assert ($state.Cancelled -eq 2 -and $state.Started -eq 1) 'shutdown does not start queued work'
    Stop-AndCheck $engine

    Write-Output ("PASS: $script:checks loopback lifecycle assertions; no operational scripts or external services executed.")
} finally {
    foreach ($engine in $engines) { $null = Stop-RequestEngine $engine -WaitMilliseconds 5000 }
    $client.Dispose()
    $transport.Dispose()
}
