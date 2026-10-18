param([ValidateRange(1024, 65535)][int]$Port = 8088)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::DefaultConnectionLimit = 32
$transport = [Net.Http.HttpClientHandler]::new()
$transport.UseProxy = $false
$client = [Net.Http.HttpClient]::new($transport)
try {
    $tasks = @(1..12 | ForEach-Object { $client.GetAsync(('http://127.0.0.1:{0}/slow' -f $Port)) })
    $statuses = foreach ($task in $tasks) {
        $response = $task.GetAwaiter().GetResult()
        try { [int]$response.StatusCode } finally { $response.Dispose() }
    }
    $statuses | Group-Object | Select-Object @{ Name = 'HttpStatus'; Expression = { $_.Name } }, Count
} finally {
    $client.Dispose()
    $transport.Dispose()
}
