[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$ScriptPath
)

# A deliberately tiny, local-only request loop.  The parent Python runtime
# keeps one bounded worker warm so a governed CAS call does not pay the
# powershell.exe process-start cost on every Resolve/Get/Set.  Requests are
# base64 JSON argument arrays; no prompt, transcript, or result is written to
# disk by this process.
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$donePrefix = '__SUPER_BRAIN_AUTHORITY_DONE__'

try {
  $resolvedScript = [IO.Path]::GetFullPath($ScriptPath)
  if (-not (Test-Path -LiteralPath $resolvedScript -PathType Leaf)) { throw 'EXECUTION_CONTRACT_SCRIPT_MISSING' }
  Remove-Item Env:SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
  $requestId = ''
  $output = [Collections.Generic.List[string]]::new()
  $responseBytes = 0
  $ok = $false
  try {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt 262144) { throw 'EXECUTION_CONTRACT_WORKER_REQUEST_INVALID' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
    $request = $json | ConvertFrom-Json
    $requestId = [string]$request.id
    $rawArgs = @($request.args)
    if ($request.schema -ne 'super-brain.execution-contract-worker-request.v1' -or
        $requestId -notmatch '^[0-9a-f]{16}$' -or
        [string]::IsNullOrWhiteSpace([string]$request.cwd) -or
        $rawArgs.Count -gt 256) {
      throw 'EXECUTION_CONTRACT_WORKER_REQUEST_INVALID'
    }
    $argumentList = @($rawArgs | ForEach-Object {
      $item = [string]$_
      if ($item.Length -gt 16384) { throw 'EXECUTION_CONTRACT_WORKER_ARGUMENT_TOO_LARGE' }
      $item
    })
    $commandInfo = Get-Command -Name $resolvedScript -CommandType ExternalScript
    $parameters = @{}
    $seenParameters = @{}
    $switchNames = @{}
    foreach ($entry in $commandInfo.Parameters.GetEnumerator()) {
      if ($entry.Value.ParameterType -eq [System.Management.Automation.SwitchParameter]) {
        $switchNames[[string]$entry.Key] = $true
      }
    }
    for ($index = 0; $index -lt $argumentList.Count;) {
      $token = [string]$argumentList[$index]
      if ($token -notmatch '^-([A-Za-z][A-Za-z0-9_]*)$' -or -not $commandInfo.Parameters.ContainsKey($Matches[1])) {
        throw 'EXECUTION_CONTRACT_WORKER_ARGUMENT_INVALID'
      }
      $name = [string]$Matches[1]
      if ($seenParameters.ContainsKey($name)) { throw 'EXECUTION_CONTRACT_WORKER_DUPLICATE_ARGUMENT' }
      $seenParameters[$name] = $true
      if ($switchNames.ContainsKey($name)) {
        $parameters[$name] = $true
        $index++
        continue
      }
      if ($index + 1 -ge $argumentList.Count) { throw 'EXECUTION_CONTRACT_WORKER_ARGUMENT_VALUE_MISSING' }
      $parameters[$name] = [string]$argumentList[$index + 1]
      $index += 2
    }
    if ($parameters.ContainsKey('SessionKey')) {
      $env:SUPER_BRAIN_LOCAL_SESSION_ID = [string]$parameters['SessionKey']
    }
    # Stream the script's normal output into a bounded list, then emit one
    # private marker so the Python side can reuse the process without guessing
    # JSON boundaries.  This keeps an accidental verbose/error response from
    # being fully buffered before the transport cap is applied.
    $workerLocation = (Get-Location).Path
    try {
      # Match the cold authority's caller cwd for this request only.  The
      # finally block restores the package cwd before the next request or any
      # caller-side temporary-directory cleanup.
      Set-Location -LiteralPath ([IO.Path]::GetFullPath([string]$request.cwd))
      & $resolvedScript @parameters 2>&1 | ForEach-Object {
        $itemText = [string]$_
        $responseBytes += [Text.Encoding]::UTF8.GetByteCount($itemText) + 1
        if ($responseBytes -gt 1048576) { throw 'EXECUTION_CONTRACT_WORKER_RESPONSE_TOO_LARGE' }
        [void]$output.Add($itemText)
      }
    } finally {
      Set-Location -LiteralPath $workerLocation
    }
    # ``-NoExit`` keeps the script inside this process.  A valid authority
    # response may itself have ``ok=false``; callers inspect that JSON field,
    # while this transport code reports success when the script executed.
    $ok = $true
  } catch {
    $output = [Collections.Generic.List[string]]::new()
    [void]$output.Add([string]$_.Exception.Message)
  }
  foreach ($item in @($output)) {
    [Console]::Out.WriteLine([string]$item)
  }
  [Console]::Out.WriteLine($donePrefix + $requestId + ':' + $(if ($ok) { '0' } else { '1' }))
  [Console]::Out.Flush()
}
