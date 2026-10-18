param([ValidateRange(1024, 65535)][int]$Port = 8088)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../RequestEngine.psd1') -Force
$engine = Start-RequestEngine -Port $Port -Workers 2 -QueueCapacity 2 -Handler {
    param($Request, $CancellationToken)
    switch ($Request.Path) {
        '/health' { $message = 'ready' }
        '/slow' { Start-Sleep -Milliseconds 500; $message = 'synthetic work completed' }
        default { $message = 'Try /health or /slow' }
    }
    @{ StatusCode = 200; ContentType = 'application/json; charset=utf-8'
        Body = (@{ requestId = $Request.Id; path = $Request.Path; message = $message } | ConvertTo-Json -Compress) }
}
try {
    Write-Host ('Synthetic listener: ' + $engine.Uri)
    $null = Read-Host 'Press Enter to stop'
} finally {
    Stop-RequestEngine $engine
}
