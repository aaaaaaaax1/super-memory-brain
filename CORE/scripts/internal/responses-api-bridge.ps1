function Throw-SuperBrainResponsesError([string]$Code,[string]$Message) {
  throw [InvalidOperationException]::new("$Code|$Message")
}

function Get-SuperBrainTextSha256([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Get-SuperBrainEnvironmentValue([string]$Name) {
  foreach ($scope in @('Process','User','Machine')) {
    $value = [Environment]::GetEnvironmentVariable($Name,$scope)
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
  }
  return ''
}

function Get-SuperBrainCodexHome {
  $configured = Get-SuperBrainEnvironmentValue 'CODEX_HOME'
  if (-not [string]::IsNullOrWhiteSpace($configured)) { return [IO.Path]::GetFullPath($configured) }
  return (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex')
}

function Read-SuperBrainManagedSmagCredential {
  $path = Join-Path (Get-SuperBrainCodexHome) 'secrets\smag.local.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { $value = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { return $null }
  $baseUrl = if ($null -ne $value.PSObject.Properties['base_url']) { ([string]$value.base_url).Trim() } else { '' }
  $apiKey = if ($null -ne $value.PSObject.Properties['api_key']) { ([string]$value.api_key).Trim() } else { '' }
  if ([string]::IsNullOrWhiteSpace($baseUrl) -and [string]::IsNullOrWhiteSpace($apiKey)) { return $null }
  return [pscustomobject]@{ baseUrl=$baseUrl; apiKey=$apiKey }
}

function Read-SuperBrainCodexDesktopCredential {
  $configPath = Join-Path (Get-SuperBrainCodexHome) 'config.toml'
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    return [pscustomobject]@{ found=$false; valid=$false; code='CODEX_CONFIG_NOT_FOUND'; responsesUrl=''; apiKey='' }
  }
  $packageRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $client = Join-Path $packageRoot 'runtime\responses_api_client.py'
  if (-not (Test-Path -LiteralPath $client -PathType Leaf)) {
    return [pscustomobject]@{ found=$true; valid=$false; code='RESPONSES_CLIENT_MISSING'; responsesUrl=''; apiKey='' }
  }
  $python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $python -or [string]::IsNullOrWhiteSpace([string]$python.Source)) {
    return [pscustomobject]@{ found=$true; valid=$false; code='CODEX_CONFIG_PYTHON_MISSING'; responsesUrl=''; apiKey='' }
  }
  $raw = @(& $python.Source $client '--resolve-codex-config' $configPath 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  try { $result = $text | ConvertFrom-Json } catch {
    return [pscustomobject]@{ found=$true; valid=$false; code='CODEX_CONFIG_RESOLUTION_INVALID'; responsesUrl=''; apiKey='' }
  }
  if ($exitCode -ne 0 -or $null -eq $result -or $result.ok -ne $true) {
    $code = if ($null -ne $result -and $result.PSObject.Properties['code']) { [string]$result.code } else { 'CODEX_CONFIG_RESOLUTION_FAILED' }
    return [pscustomobject]@{ found=$true; valid=$false; code=$code; responsesUrl=''; apiKey='' }
  }
  $responsesUrl = if ($result.PSObject.Properties['responsesUrl']) { [string]$result.responsesUrl } else { '' }
  $apiKey = if ($result.PSObject.Properties['apiKey']) { [string]$result.apiKey } else { '' }
  if ([string]::IsNullOrWhiteSpace($responsesUrl) -or [string]::IsNullOrWhiteSpace($apiKey)) {
    return [pscustomobject]@{ found=$true; valid=$false; code='CODEX_CONFIG_RESOLUTION_INCOMPLETE'; responsesUrl=''; apiKey='' }
  }
  return [pscustomobject]@{ found=$true; valid=$true; code=''; responsesUrl=$responsesUrl; apiKey=$apiKey }
}

function ConvertTo-SuperBrainResponsesUrl([string]$Url,[switch]$FromBaseUrl) {
  if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
  try { $uri = [uri]$Url } catch { Throw-SuperBrainResponsesError 'RESPONSES_URL_INVALID' 'Responses URL is invalid.' }
  if (-not $uri.IsAbsoluteUri) { Throw-SuperBrainResponsesError 'RESPONSES_URL_INVALID' 'Responses URL must be absolute.' }
  $localHttp = $uri.Scheme -eq 'http' -and $uri.Host -in @('127.0.0.1','localhost','::1')
  if ($uri.Scheme -ne 'https' -and -not $localHttp) {
    Throw-SuperBrainResponsesError 'RESPONSES_URL_INSECURE' 'Only HTTPS or loopback HTTP Responses endpoints are allowed.'
  }
  if (-not $FromBaseUrl) { return $uri.AbsoluteUri }

  $builder = [UriBuilder]::new($uri)
  $path = ([string]$builder.Path).TrimEnd('/')
  if ($path.EndsWith('/v1/responses',[StringComparison]::OrdinalIgnoreCase)) { $next = $path }
  elseif ($path.EndsWith('/responses',[StringComparison]::OrdinalIgnoreCase)) { $next = $path.Substring(0,$path.Length - '/responses'.Length) + '/v1/responses' }
  elseif ($path.EndsWith('/v1',[StringComparison]::OrdinalIgnoreCase)) { $next = $path + '/responses' }
  else { $next = $path + '/v1/responses' }
  if ([string]::IsNullOrWhiteSpace($next)) { $next = '/v1/responses' }
  $builder.Path = $next
  $builder.Query = ''
  $builder.Fragment = ''
  return $builder.Uri.AbsoluteUri
}

function Resolve-SuperBrainResponsesConnection {
  param(
    [string]$ExplicitResponsesUrl = '',
    [string]$PrimaryResponsesUrlEnvironment = '',
    [string]$ApiKeyEnvironment = ''
  )

  $explicitKey = if ([string]::IsNullOrWhiteSpace($ApiKeyEnvironment)) { '' } else { Get-SuperBrainEnvironmentValue $ApiKeyEnvironment }
  if (-not [string]::IsNullOrWhiteSpace($ExplicitResponsesUrl)) {
    return [pscustomobject]@{
      responsesUrl = ConvertTo-SuperBrainResponsesUrl $ExplicitResponsesUrl
      apiKey = $explicitKey
      endpointSource = 'explicit_parameter'
      credentialSource = if ([string]::IsNullOrWhiteSpace($explicitKey)) { 'none' } elseif ($ApiKeyEnvironment -like 'SUPER_BRAIN_*') { 'super_brain_environment' } else { 'explicit_environment' }
      configured = (-not [string]::IsNullOrWhiteSpace($explicitKey))
      resolutionCode = if ([string]::IsNullOrWhiteSpace($explicitKey)) { 'RESPONSES_API_KEY_MISSING' } else { 'OK' }
    }
  }
  $primaryUrl = if ([string]::IsNullOrWhiteSpace($PrimaryResponsesUrlEnvironment)) { '' } else { Get-SuperBrainEnvironmentValue $PrimaryResponsesUrlEnvironment }
  if (-not [string]::IsNullOrWhiteSpace($primaryUrl)) {
    return [pscustomobject]@{
      responsesUrl = ConvertTo-SuperBrainResponsesUrl $primaryUrl
      apiKey = $explicitKey
      endpointSource = 'super_brain_environment'
      credentialSource = if ([string]::IsNullOrWhiteSpace($explicitKey)) { 'none' } else { 'super_brain_environment' }
      configured = (-not [string]::IsNullOrWhiteSpace($explicitKey))
      resolutionCode = if ([string]::IsNullOrWhiteSpace($explicitKey)) { 'RESPONSES_API_KEY_MISSING' } else { 'OK' }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($explicitKey)) {
    return [pscustomobject]@{
      responsesUrl = ''
      apiKey = $explicitKey
      endpointSource = 'none'
      credentialSource = if ($ApiKeyEnvironment -like 'SUPER_BRAIN_*') { 'super_brain_environment' } else { 'explicit_environment' }
      configured = $false
      resolutionCode = 'RESPONSES_URL_MISSING'
    }
  }

  $codex = Read-SuperBrainCodexDesktopCredential
  if ($codex.found) {
    if ($codex.valid -ne $true) {
      return [pscustomobject]@{ responsesUrl=''; apiKey=''; endpointSource='codex_desktop_config'; credentialSource='none'; configured=$false; resolutionCode=[string]$codex.code }
    }
    return [pscustomobject]@{ responsesUrl=[string]$codex.responsesUrl; apiKey=[string]$codex.apiKey; endpointSource='codex_desktop_config'; credentialSource='codex_desktop_config'; configured=$true; resolutionCode='OK' }
  }

  $managed = Read-SuperBrainManagedSmagCredential
  if ($null -ne $managed -and -not [string]::IsNullOrWhiteSpace([string]$managed.baseUrl) -and -not [string]::IsNullOrWhiteSpace([string]$managed.apiKey)) {
    return [pscustomobject]@{ responsesUrl=(ConvertTo-SuperBrainResponsesUrl ([string]$managed.baseUrl) -FromBaseUrl); apiKey=[string]$managed.apiKey; endpointSource='smag_managed_cache'; credentialSource='smag_managed_cache'; configured=$true; resolutionCode='OK' }
  }

  $smagUrl = Get-SuperBrainEnvironmentValue 'SMAG_RESPONSES_URL'
  $smagKey = Get-SuperBrainEnvironmentValue 'SMAG_API_KEY'
  if (-not [string]::IsNullOrWhiteSpace($smagUrl) -or -not [string]::IsNullOrWhiteSpace($smagKey)) {
    return [pscustomobject]@{
      responsesUrl = if ([string]::IsNullOrWhiteSpace($smagUrl)) { '' } else { ConvertTo-SuperBrainResponsesUrl $smagUrl -FromBaseUrl }
      apiKey = $smagKey
      endpointSource = if ([string]::IsNullOrWhiteSpace($smagUrl)) { 'none' } else { 'smag_environment' }
      credentialSource = if ([string]::IsNullOrWhiteSpace($smagKey)) { 'none' } else { 'smag_environment' }
      configured = (-not [string]::IsNullOrWhiteSpace($smagUrl) -and -not [string]::IsNullOrWhiteSpace($smagKey))
      resolutionCode = if ([string]::IsNullOrWhiteSpace($smagUrl)) { 'RESPONSES_URL_MISSING' } elseif ([string]::IsNullOrWhiteSpace($smagKey)) { 'RESPONSES_API_KEY_MISSING' } else { 'OK' }
    }
  }

  return [pscustomobject]@{
    responsesUrl = ''
    apiKey = ''
    endpointSource = 'none'
    credentialSource = 'none'
    configured = $false
    resolutionCode = 'RESPONSES_CONNECTION_MISSING'
  }
}

function Get-SuperBrainResponsesTransportReceiptRoot {
  $configured = Get-SuperBrainEnvironmentValue 'SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT'
  if (-not [string]::IsNullOrWhiteSpace($configured)) { return [IO.Path]::GetFullPath($configured) }
  $stateRoot = Get-SuperBrainEnvironmentValue 'SUPER_BRAIN_STATE_ROOT'
  if (-not [string]::IsNullOrWhiteSpace($stateRoot)) { return (Join-Path ([IO.Path]::GetFullPath($stateRoot)) 'transport-receipts') }
  $packageRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  return (Join-Path $packageRoot 'private-state\transport-receipts')
}

function Get-SuperBrainResponsesTransportReceiptPath([string]$Scope) {
  if ($Scope -notmatch '^[a-z0-9-]{3,80}$') { Throw-SuperBrainResponsesError 'RESPONSES_TRANSPORT_SCOPE_INVALID' 'Transport receipt scope is invalid.' }
  return (Join-Path (Get-SuperBrainResponsesTransportReceiptRoot) ($Scope + '.json'))
}

function Get-SuperBrainResponsesTransportBinding([uri]$Uri,[string]$Model,[string]$ReasoningEffort) {
  if ($null -eq $Uri -or [string]::IsNullOrWhiteSpace($Model) -or [string]::IsNullOrWhiteSpace($ReasoningEffort)) { Throw-SuperBrainResponsesError 'RESPONSES_TRANSPORT_BINDING_INVALID' 'Transport binding is incomplete.' }
  $packageRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $clientPath = Join-Path $packageRoot 'runtime\responses_api_client.py'
  $bridgePath = Join-Path $packageRoot 'scripts\internal\responses-api-bridge.ps1'
  if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf) -or -not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) { Throw-SuperBrainResponsesError 'RESPONSES_TRANSPORT_BINDING_MISSING' 'Responses transport binding files are missing.' }
  $endpointHash = Get-SuperBrainTextSha256 $Uri.AbsoluteUri
  $clientHash = Get-SuperBrainTextSha256 ([IO.File]::ReadAllText($clientPath,[Text.Encoding]::UTF8))
  $bridgeHash = Get-SuperBrainTextSha256 ([IO.File]::ReadAllText($bridgePath,[Text.Encoding]::UTF8))
  $fingerprint = Get-SuperBrainTextSha256 ($endpointHash + "`n" + $Model + "`n" + $ReasoningEffort + "`n" + $clientHash + "`n" + $bridgeHash)
  return [pscustomobject]@{ endpointSha256=$endpointHash; clientSha256=$clientHash; bridgeSha256=$bridgeHash; fingerprint=$fingerprint }
}

function Write-SuperBrainResponsesTransportProbeReceipt {
  param(
    [Parameter(Mandatory=$true)][string]$Scope,
    [Parameter(Mandatory=$true)][uri]$Uri,
    [Parameter(Mandatory=$true)][string]$Model,
    [Parameter(Mandatory=$true)][string]$ReasoningEffort
  )
  $binding = Get-SuperBrainResponsesTransportBinding $Uri $Model $ReasoningEffort
  $path = Get-SuperBrainResponsesTransportReceiptPath $Scope
  $parent = Split-Path -Parent $path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $receipt = [ordered]@{
    schema = 'super-brain.responses-transport-probe.v1'
    scope = $Scope
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    endpointSha256 = $binding.endpointSha256
    model = $Model
    reasoningEffort = $ReasoningEffort
    responsesClientSha256 = $binding.clientSha256
    bridgeSha256 = $binding.bridgeSha256
    bindingFingerprint = $binding.fingerprint
    rawResponseStored = $false
    credentialStored = $false
  }
  $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
  $backup = "$path.$([guid]::NewGuid().ToString('N')).bak"
  try {
    [IO.File]::WriteAllText($temporary,(($receipt | ConvertTo-Json -Depth 8) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      [IO.File]::Replace($temporary,$path,$backup)
    } else {
      [IO.File]::Move($temporary,$path)
    }
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
  }
  return [pscustomobject]@{ path=$path; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); bindingFingerprint=$binding.fingerprint }
}

function Test-SuperBrainResponsesTransportProbeReceipt {
  param(
    [Parameter(Mandatory=$true)][string]$Scope,
    [Parameter(Mandatory=$true)][uri]$Uri,
    [Parameter(Mandatory=$true)][string]$Model,
    [Parameter(Mandatory=$true)][string]$ReasoningEffort,
    [ValidateRange(1,168)][int]$MaxAgeHours = 24
  )
  $path = Get-SuperBrainResponsesTransportReceiptPath $Scope
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ ok=$false; code='RESPONSES_TRANSPORT_PROBE_REQUIRED'; receiptSha256='' } }
  try { $receipt = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return [pscustomobject]@{ ok=$false; code='RESPONSES_TRANSPORT_PROBE_INVALID'; receiptSha256='' } }
  $binding = Get-SuperBrainResponsesTransportBinding $Uri $Model $ReasoningEffort
  $created = [DateTime]::MinValue
  try { $created = [DateTime]::Parse([string]$receipt.createdAtUtc).ToUniversalTime() } catch { return [pscustomobject]@{ ok=$false; code='RESPONSES_TRANSPORT_PROBE_INVALID'; receiptSha256='' } }
  if (([DateTime]::UtcNow - $created).TotalHours -gt $MaxAgeHours) { return [pscustomobject]@{ ok=$false; code='RESPONSES_TRANSPORT_PROBE_STALE'; receiptSha256='' } }
  if ([string]$receipt.schema -ne 'super-brain.responses-transport-probe.v1' -or [string]$receipt.scope -ne $Scope -or [string]$receipt.bindingFingerprint -ne $binding.fingerprint) {
    return [pscustomobject]@{ ok=$false; code='RESPONSES_TRANSPORT_PROBE_MISMATCH'; receiptSha256='' }
  }
  return [pscustomobject]@{ ok=$true; code='OK'; receiptSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Assert-SuperBrainResponsesTransportProbeReceipt {
  param(
    [Parameter(Mandatory=$true)][string]$Scope,
    [Parameter(Mandatory=$true)][uri]$Uri,
    [Parameter(Mandatory=$true)][string]$Model,
    [Parameter(Mandatory=$true)][string]$ReasoningEffort,
    [ValidateRange(1,168)][int]$MaxAgeHours = 24
  )
  $result = Test-SuperBrainResponsesTransportProbeReceipt -Scope $Scope -Uri $Uri -Model $Model -ReasoningEffort $ReasoningEffort -MaxAgeHours $MaxAgeHours
  if ($result.ok -ne $true) { Throw-SuperBrainResponsesError ([string]$result.code) 'A matching successful Responses probe is required before batch generation.' }
  return $result
}

function Test-SuperBrainLocalCodexResponsesEndpoint([uri]$Uri) {
  if ($null -eq $Uri) { return $false }
  if ($Uri.Scheme -ne 'http' -or $Uri.Host -notin @('127.0.0.1','localhost','::1')) { return $false }
  return $Uri.AbsolutePath.TrimEnd('/') -ieq '/codex/v1/responses'
}

function ConvertFrom-SuperBrainResponsesEventStream([string]$Content) {
  if ([string]::IsNullOrWhiteSpace($Content)) { Throw-SuperBrainResponsesError 'RESPONSES_RESPONSE_INVALID' 'Responses event stream is empty.' }
  $completed = $null
  foreach ($block in @([regex]::Split($Content,'\r?\n\r?\n'))) {
    if ([string]::IsNullOrWhiteSpace($block)) { continue }
    $eventName = ''
    $dataLines = New-Object Collections.ArrayList
    foreach ($line in @([regex]::Split($block,'\r?\n'))) {
      if ($line -match '^event:\s*(.+)$') { $eventName = $matches[1].Trim(); continue }
      if ($line -match '^data:\s?(.*)$') { [void]$dataLines.Add($matches[1]) }
    }
    if ($dataLines.Count -eq 0) { continue }
    $payload = (@($dataLines) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($payload) -or $payload -eq '[DONE]') { continue }
    try { $eventValue = $payload | ConvertFrom-Json }
    catch { Throw-SuperBrainResponsesError 'RESPONSES_RESPONSE_INVALID' 'Responses event stream contains invalid JSON data.' }
    $eventType = if ($null -ne $eventValue.PSObject.Properties['type']) { [string]$eventValue.type } else { $eventName }
    if ($eventName -eq 'response.completed' -or $eventType -eq 'response.completed') { $completed = $eventValue }
  }
  if ($null -eq $completed) { Throw-SuperBrainResponsesError 'RESPONSES_RESPONSE_INCOMPLETE' 'Responses event stream has no response.completed event.' }
  if ($null -ne $completed.PSObject.Properties['response'] -and $null -ne $completed.response) { return $completed.response }
  return $completed
}

function Get-SuperBrainResponsesModel($Response) {
  if ($null -ne $Response -and $null -ne $Response.PSObject.Properties['model'] -and -not [string]::IsNullOrWhiteSpace([string]$Response.model)) { return [string]$Response.model }
  if ($null -ne $Response -and $null -ne $Response.PSObject.Properties['response'] -and $null -ne $Response.response -and $null -ne $Response.response.PSObject.Properties['model'] -and -not [string]::IsNullOrWhiteSpace([string]$Response.response.model)) { return [string]$Response.response.model }
  Throw-SuperBrainResponsesError 'RESPONSES_REPORTED_MODEL_MISSING' 'Responses reply does not report its actual model identity.'
}

function Get-SuperBrainResponsesId($Response) {
  if ($null -ne $Response -and $null -ne $Response.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$Response.id)) { return [string]$Response.id }
  if ($null -ne $Response -and $null -ne $Response.PSObject.Properties['response'] -and $null -ne $Response.response -and $null -ne $Response.response.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$Response.response.id)) { return [string]$Response.response.id }
  Throw-SuperBrainResponsesError 'RESPONSES_ID_MISSING' 'Responses reply does not include a response id.'
}

function Get-SuperBrainResponsesText($Response) {
  if ($null -ne $Response -and $null -ne $Response.PSObject.Properties['output_text'] -and -not [string]::IsNullOrWhiteSpace([string]$Response.output_text)) { return [string]$Response.output_text }
  foreach ($output in @($Response.output)) {
    if ([string]$output.type -ne 'message') { continue }
    foreach ($content in @($output.content)) {
      if ([string]$content.type -notin @('output_text','text','')) { continue }
      if ($null -ne $content -and $null -ne $content.PSObject.Properties['text']) {
        if ($content.text -is [string]) { return [string]$content.text }
        if ($null -ne $content.text -and $null -ne $content.text.PSObject.Properties['value']) { return [string]$content.text.value }
      }
    }
  }
  foreach ($output in @($Response.output)) {
    foreach ($content in @($output.content)) {
      if ($null -ne $content -and $null -ne $content.PSObject.Properties['text']) {
        if ($content.text -is [string]) { return [string]$content.text }
        if ($null -ne $content.text -and $null -ne $content.text.PSObject.Properties['value']) { return [string]$content.text.value }
      }
    }
  }
  foreach ($choice in @($Response.choices)) {
    if ($null -ne $choice.message -and -not [string]::IsNullOrWhiteSpace([string]$choice.message.content)) { return [string]$choice.message.content }
  }
  Throw-SuperBrainResponsesError 'RESPONSES_RESPONSE_INVALID' 'Responses reply contains no text output.'
}

function Invoke-SuperBrainResponsesRequest {
  param(
    [uri]$Uri,
    [string]$ApiKey,
    [string]$Model,
    [string]$ReasoningEffort,
    [object]$RequestInput,
    [string]$Instructions = '',
    [object]$JsonSchema = $null,
    [ValidateRange(16,32768)][int]$MaxOutputTokens = 1024,
    [ValidateRange(5,300)][int]$TimeoutSeconds = 45
  )

  # Atoapi's local Codex endpoint requires canonical structured Responses input.
  $inputValue = $RequestInput
  if ($RequestInput -is [string] -and (Test-SuperBrainLocalCodexResponsesEndpoint $Uri)) {
    # Do not assign this through an if-expression: PowerShell enumerates a
    # single-item array there and emits an object, while Codex requires input
    # to remain a JSON array.
    $inputValue = [object[]]@([pscustomobject]@{
      type = 'message'
      role = 'user'
      content = @([pscustomobject]@{ type = 'input_text'; text = [string]$RequestInput })
    })
  }
  $bodyValue = [ordered]@{
    model = $Model
    reasoning = [pscustomobject]@{ effort = $ReasoningEffort }
    input = $inputValue
    max_output_tokens = $MaxOutputTokens
    stream = $true
  }
  if (Test-SuperBrainLocalCodexResponsesEndpoint $Uri) {
    # Keep sealed-evaluation turns out of Atoapi's retained conversation state.
    $bodyValue['store'] = $false
  }
  if (-not [string]::IsNullOrWhiteSpace($Instructions)) { $bodyValue['instructions'] = $Instructions }
  # The configured Codex-compatible provider is verified for freeform
  # Responses JSON, while its json_schema capability is not. The downstream
  # generators still validate every returned JSON object before accepting it.
  if ($null -ne $JsonSchema -and -not (Test-SuperBrainLocalCodexResponsesEndpoint $Uri)) {
    $bodyValue['text'] = [ordered]@{
      format = [ordered]@{
        type = 'json_schema'
        name = 'super_brain_phase6_answer'
        strict = $true
        schema = $JsonSchema
      }
    }
  }
  $transportInput = [pscustomobject]@{
    endpoint = $Uri.AbsoluteUri
    apiKey = $ApiKey
    timeoutSeconds = $TimeoutSeconds
    payload = [pscustomobject]$bodyValue
  } | ConvertTo-Json -Depth 18 -Compress
  $packageRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $client = Join-Path $packageRoot 'runtime\responses_api_client.py'
  if (-not (Test-Path -LiteralPath $client -PathType Leaf)) { Throw-SuperBrainResponsesError 'RESPONSES_CLIENT_MISSING' 'Responses transport client is missing.' }
  $python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $python -or [string]::IsNullOrWhiteSpace([string]$python.Source)) {
    Throw-SuperBrainResponsesError 'RESPONSES_PYTHON_MISSING' 'Responses transport client requires a resolvable Python executable.'
  }
  $startInfo = New-Object Diagnostics.ProcessStartInfo
  # Resolve once in the parent process. A bare command can select a different
  # Python through the child process PATH and change local-proxy behavior.
  $startInfo.FileName = [string]$python.Source
  $startInfo.Arguments = '"' + $client.Replace('"','\"') + '" --stdin-envelope'
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $utf8 = [Text.UTF8Encoding]::new($false)
  $startInfo.StandardOutputEncoding = $utf8
  $startInfo.StandardErrorEncoding = $utf8
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $startInfo
  try {
    [void]$process.Start()
    # Windows PowerShell 5 cannot configure StandardInputEncoding. Writing the
    # UTF-8 envelope to the underlying stream avoids locale-dependent corruption.
    $transportBytes = $utf8.GetBytes($transportInput + [Environment]::NewLine)
    $process.StandardInput.BaseStream.Write($transportBytes,0,$transportBytes.Length)
    $process.StandardInput.BaseStream.Flush()
    $process.StandardInput.Close()
    $text = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if (-not $process.WaitForExit(($TimeoutSeconds + 15) * 1000)) {
      try { $process.Kill() } catch {}
      Throw-SuperBrainResponsesError 'RESPONSES_CLIENT_TIMEOUT' 'Responses transport client timed out.'
    }
    $exitCode = $process.ExitCode
  } finally {
    $process.Dispose()
  }
  if ([string]::IsNullOrWhiteSpace($text)) {
    Throw-SuperBrainResponsesError 'RESPONSES_CLIENT_INVALID_OUTPUT' 'Responses transport client returned no machine-readable output.'
  }
  try { $clientResult = $text | ConvertFrom-Json } catch { Throw-SuperBrainResponsesError 'RESPONSES_CLIENT_INVALID_OUTPUT' 'Responses transport client returned invalid output.' }
  if ($null -eq $clientResult) { Throw-SuperBrainResponsesError 'RESPONSES_CLIENT_INVALID_OUTPUT' 'Responses transport client returned no machine-readable output.' }
  if ($exitCode -ne 0 -or $clientResult.ok -ne $true) {
    $code = if ($null -ne $clientResult.PSObject.Properties['code']) { [string]$clientResult.code } else { 'RESPONSES_API_FAILED' }
    Throw-SuperBrainResponsesError $code 'Responses transport client rejected the request.'
  }
  $response = $clientResult.response
  if ($null -eq $response) { Throw-SuperBrainResponsesError 'RESPONSES_RESPONSE_INVALID' 'Responses transport client omitted the final response.' }
  $reportedModel = Get-SuperBrainResponsesModel $response
  if ($reportedModel -ne $Model) { Throw-SuperBrainResponsesError 'RESPONSES_REPORTED_MODEL_MISMATCH' "Responses requested $Model but the reply reported $reportedModel." }
  return [pscustomobject]@{ response=$response; reportedModel=$reportedModel }
}

function Test-SuperBrainRetryableProbeFailure([object]$ErrorRecord) {
  $message = if ($null -eq $ErrorRecord) { '' } elseif ($ErrorRecord.PSObject.Properties['Exception'] -and $null -ne $ErrorRecord.Exception) { [string]$ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
  $code = (($message -split '\|',2)[0]).Trim()
  return $code -in @(
    'RESPONSES_HTTP_408',
    'RESPONSES_HTTP_425',
    'RESPONSES_HTTP_429',
    'RESPONSES_HTTP_500',
    'RESPONSES_HTTP_502',
    'RESPONSES_HTTP_503',
    'RESPONSES_HTTP_504',
    'RESPONSES_CLIENT_TIMEOUT',
    'RESPONSES_RESPONSE_INCOMPLETE'
  )
}

function Invoke-SuperBrainResponsesProbe {
  param(
    [uri]$Uri,
    [string]$ApiKey,
    [string]$Model,
    [string]$ReasoningEffort,
    [object]$RequestInput,
    [object]$JsonSchema = $null,
    [ValidateRange(16,32768)][int]$MaxOutputTokens = 1024,
    [ValidateRange(5,300)][int]$TimeoutSeconds = 45,
    [ValidateRange(1,3)][int]$MaxAttempts = 3,
    [ValidateRange(0,10000)][int]$RetryDelayMilliseconds = 750
  )

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      $result = Invoke-SuperBrainResponsesRequest -Uri $Uri -ApiKey $ApiKey -Model $Model -ReasoningEffort $ReasoningEffort -RequestInput $RequestInput -JsonSchema $JsonSchema -MaxOutputTokens $MaxOutputTokens -TimeoutSeconds $TimeoutSeconds
      return [pscustomobject]@{
        result = $result
        attemptCount = $attempt
        retryCount = $attempt - 1
      }
    } catch {
      if ($attempt -ge $MaxAttempts -or -not (Test-SuperBrainRetryableProbeFailure $_)) { throw }
      if ($RetryDelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds ([Math]::Min(10000, $RetryDelayMilliseconds * $attempt))
      }
    }
  }

  Throw-SuperBrainResponsesError 'RESPONSES_PROBE_RETRY_EXHAUSTED' 'Responses probe exhausted its bounded retry budget.'
}
