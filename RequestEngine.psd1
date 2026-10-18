@{
    RootModule = 'RequestEngine.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'f89d7ac3-fc10-4fc9-ad9f-eb36b06d0d71'
    Author = 'Derek Poe'
    Copyright = '(c) Derek Poe. MIT License.'
    Description = 'Bounded loopback HTTP request scheduling with explicit PowerShell runspace ownership.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Start-RequestEngine', 'Get-RequestEngineState', 'Stop-RequestEngineRequest', 'Stop-RequestEngine')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Tags = @('HttpListener', 'Runspaces', 'Concurrency', 'Backpressure') } }
}
