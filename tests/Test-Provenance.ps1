$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content -LiteralPath (Join-Path $root 'historical/provenance.json') -Raw | ConvertFrom-Json
$reference = Join-Path $root $manifest.referenceFile
if ((Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash -ne $manifest.referenceSha256) { throw 'Historical reference hash mismatch.' }
$tokens = $null
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($reference, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Historical scheduler excerpt does not parse.' }
$null = Test-ModuleManifest (Join-Path $root 'RequestEngine.psd1')
Write-Output 'PASS: historical excerpt hash and syntax; module manifest. Reference source was not executed.'
