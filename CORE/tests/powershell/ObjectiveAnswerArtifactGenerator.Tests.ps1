$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$generatorPath = Join-Path $root 'scripts\objective-answer-artifact-generator.ps1'
$runnerPath = Join-Path $root 'scripts\objective-benchmark-runner.ps1'

function Get-ObjectiveTestDrivePath {
  return (Get-Item -LiteralPath $TestDrive).FullName
}

function Write-ObjectiveGeneratorTestJson([string]$Path, $Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  if ($Value -and [string]$Value.schema -eq 'super-brain.objective-answer-input.v1' -and $null -eq $Value.PSObject.Properties['pairContract']) {
    $caseParts = @($Value.cases | Sort-Object id | ForEach-Object {
      $shape = Get-ObjectiveTestHash (([string]$_.id) + "`n" + ([string]$_.prompt) + "`n" + ([string]$_.reference) + "`n" + ([string]$_.rubric))
      ([string]$_.id) + "`n" + $shape
    })
    $caseSetHash = Get-ObjectiveTestHash ($caseParts -join "`n")
    $contractPath = Join-Path (Get-ObjectiveTestDrivePath) ("pair-contract-" + $caseSetHash + '.json')
    if (-not (Test-Path -LiteralPath $contractPath)) {
      $contract = [pscustomobject]@{
        schema='super-brain.objective-pair-contract.v1'
        benchmark=[pscustomobject]@{ id='longmemeval'; variant='s_cleaned'; corpusSha256=[string]$Value.benchmark.corpusSha256; harnessSha256=[string]$Value.benchmark.harnessSha256 }
        selection=[pscustomobject]@{ selectionSha256=[string]$Value.benchmark.selectionSha256; caseSetHash=$caseSetHash; caseCount=@($Value.cases).Count }
        generationBudget=[pscustomobject]@{ modelId='gpt-5.6-terra'; reasoningEffort='max'; maxOutputTokens=512; timeoutSeconds=30; batchSize=10; maxBatchAttempts=1; retrievalTopK=10; retrievalMaxTokens=2000 }
        singleChangedVariable='super_memory_brain_enabled'
        baseline=[pscustomobject]@{ superMemoryBrainEnabled=$false }
        treatment=[pscustomobject]@{ superMemoryBrainEnabled=$true }
      }
      [IO.File]::WriteAllText($contractPath, ($contract | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
    }
    $Value | Add-Member -NotePropertyName pairContract -NotePropertyValue ([pscustomobject]@{ path=$contractPath; sha256=(Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant() })
  }
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 24), [Text.UTF8Encoding]::new($false))
}

function Invoke-ObjectiveGenerator([string[]]$Arguments) {
  $previousReceiptRoot = $env:SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT
  $env:SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT = Join-Path (Get-ObjectiveTestDrivePath) 'transport-receipts'
  try {
    # Windows PowerShell can collapse an array passed after -File. Keep named
    # switches as tokens and quote only their values for the child command.
    $escapedPath = $generatorPath.Replace("'", "''")
    $argumentTokens = @($Arguments | ForEach-Object {
      $value = [string]$_
      if ($value -match '^-([A-Za-z][A-Za-z0-9]*)$') { $value } else { "'" + $value.Replace("'", "''") + "'" }
    })
    $command = "& '$escapedPath' " + ($argumentTokens -join ' ')
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command 2>$null)
    return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=(($raw -join "`n") | ConvertFrom-Json) }
  } finally {
    if ($null -eq $previousReceiptRoot) { Remove-Item Env:\SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT = $previousReceiptRoot }
  }
}

function Invoke-ObjectiveBlindRunner([string[]]$Arguments) {
  $escapedPath = $runnerPath.Replace("'", "''")
  $argumentTokens = @($Arguments | ForEach-Object {
    $value = [string]$_
    if ($value -match '^-([A-Za-z][A-Za-z0-9]*)$') { $value } else { "'" + $value.Replace("'", "''") + "'" }
  })
  $command = "& '$escapedPath' " + ($argumentTokens -join ' ')
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command 2>$null)
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=(($raw -join "`n") | ConvertFrom-Json) }
}

function Assert-ObjectiveGeneratorSucceeded($Result, [string]$Stage) {
  if ($Result.exitCode -ne 0) {
    $code = if ($null -ne $Result.value -and $Result.value.PSObject.Properties['code']) { [string]$Result.value.code } else { 'UNPARSEABLE_RESULT' }
    $errorText = if ($null -ne $Result.value -and $Result.value.PSObject.Properties['error']) { [string]$Result.value.error } else { '' }
    throw "OBJECTIVE_GENERATOR_STAGE_FAILED stage=$Stage exitCode=$($Result.exitCode) code=$code error=$errorText"
  }
  $Result.exitCode | Should Be 0
}

function Get-ObjectiveTestHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function New-ObjectiveGeneratorInput([bool]$Enabled, [string]$Reference = 'OBJECTIVE_REFERENCE_SENTINEL', [string]$Context = 'Retrieved context says the answer is red.', [int]$CaseCount = 1, [int]$BatchSize = 10) {
  $hashA = ('a' * 64) -join ''
  $hashB = ('b' * 64) -join ''
  $hashC = ('c' * 64) -join ''
  $cases = New-Object Collections.ArrayList
  for ($index = 1; $index -le $CaseCount; $index++) {
    [void]$cases.Add([pscustomobject]@{
      id = "case-$index"
      prompt = "What color was selected for case $index?"
      reference = if ($index -eq 1) { $Reference } else { "$Reference case $index" }
      rubric = 'Answer with the selected color.'
      retrievedContext = if ($Enabled) { "$Context Case $index." } else { '' }
    })
  }
  $input = [pscustomobject]@{
    schema = 'super-brain.objective-answer-input.v1'
    benchmark = [pscustomobject]@{ id='longmemeval'; variant='s_cleaned'; corpusSha256=$hashA; harnessSha256=$hashB; selectionSha256=$hashC }
    condition = [pscustomobject]@{ superMemoryBrainEnabled=$Enabled }
    cases = @($cases)
  }
  $caseParts = @($input.cases | Sort-Object id | ForEach-Object {
    $shape = Get-ObjectiveTestHash (([string]$_.id) + "`n" + ([string]$_.prompt) + "`n" + ([string]$_.reference) + "`n" + ([string]$_.rubric))
    ([string]$_.id) + "`n" + $shape
  })
  $caseSetHash = Get-ObjectiveTestHash ($caseParts -join "`n")
  $contractPath = Join-Path (Get-ObjectiveTestDrivePath) ("pair-contract-" + $caseSetHash + "-b$BatchSize.json")
  if (-not (Test-Path -LiteralPath $contractPath)) {
    $contract = [pscustomobject]@{
      schema='super-brain.objective-pair-contract.v1'
      benchmark=[pscustomobject]@{ id='longmemeval'; variant='s_cleaned'; corpusSha256=$hashA; harnessSha256=$hashB }
      selection=[pscustomobject]@{ selectionSha256=$hashC; caseSetHash=$caseSetHash; caseCount=@($input.cases).Count }
      generationBudget=[pscustomobject]@{ modelId='gpt-5.6-terra'; reasoningEffort='max'; maxOutputTokens=512; timeoutSeconds=30; batchSize=$BatchSize; maxBatchAttempts=1; retrievalTopK=10; retrievalMaxTokens=2000 }
      singleChangedVariable='super_memory_brain_enabled'
      baseline=[pscustomobject]@{ superMemoryBrainEnabled=$false }
      treatment=[pscustomobject]@{ superMemoryBrainEnabled=$true }
    }
    [IO.File]::WriteAllText($contractPath, ($contract | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
  }
  $input | Add-Member -NotePropertyName pairContract -NotePropertyValue ([pscustomobject]@{ path=$contractPath; sha256=(Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash.ToLowerInvariant() })
  return $input
}

function Start-ObjectiveGeneratorSseServer([string]$Model='gpt-5.6-terra', [string]$Text='{"cases":[{"id":"case-1","answer":"red"}]}', [int]$RequestCount=1, [string]$RoutePath='') {
  $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  $portProbe.Start()
  $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
  $portProbe.Stop()
  $route = $RoutePath.Trim('/')
  $prefix = if ([string]::IsNullOrWhiteSpace($route)) { "http://127.0.0.1:$port/" } else { "http://127.0.0.1:$port/$route/" }
  # Pester 3 exposes TestDrive as a virtual PSDrive. Resolve it before
  # passing paths to a background process, which does not inherit that drive.
  $testDrivePath = Get-ObjectiveTestDrivePath
  $readyPath = Join-Path $testDrivePath "objective-answer-$port.ready"
  $requestPath = Join-Path $testDrivePath "objective-answer-$port.request.json"
  $stopPath = Join-Path $testDrivePath "objective-answer-$port.stop"
  $errorPath = Join-Path $testDrivePath "objective-answer-$port.error.txt"
  Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
  # Legacy Pester jobs and HttpListener are unavailable on this host. Use a
  # self-contained Python standard-library loopback fixture for transport tests.
  $serverConfig = [pscustomobject]@{
    port=$port; readyPath=$readyPath; requestPath=$requestPath; stopPath=$stopPath; errorPath=$errorPath
    model=$Model; text=$Text; requestCount=$RequestCount
  } | ConvertTo-Json -Compress
  $configEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serverConfig))
  $serverScript = @'
import base64
import json
import os
import re
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer

config = json.loads(base64.b64decode("__OBJECTIVE_SERVER_CONFIG__").decode("utf-8"))

class ObjectiveAnswerHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        request_text = self.rfile.read(content_length).decode("utf-8", "replace")
        with open(config["requestPath"], "w", encoding="utf-8", newline="") as handle:
            handle.write(request_text)
        prompt_text = request_text
        try:
            request_value = json.loads(request_text)
            input_value = request_value.get("input")
            if isinstance(input_value, str):
                prompt_text = input_value
            elif isinstance(input_value, list) and len(input_value) == 1:
                content = input_value[0].get("content", [])
                if content and isinstance(content[0], dict) and content[0].get("text"):
                    prompt_text = str(content[0]["text"])
        except (TypeError, ValueError, AttributeError):
            pass
        case_ids = [value.strip() for value in re.findall(r"(?m)^Case id:\s*([^\r\n]+)", prompt_text)]
        response_text = json.dumps({"cases": [{"id": value, "answer": "red"} for value in case_ids]}, separators=(",", ":")) if case_ids else config["text"]
        payload = {
            "type": "response.completed",
            "response": {
                "id": "objective-answer-response-test-{}".format(self.server.handled + 1),
                "object": "response",
                "model": config["model"],
                "status": "completed",
                "output": [{"type": "message", "content": [{"type": "output_text", "text": response_text}]}],
            },
        }
        response_bytes = ("event: response.completed\n" + "data: " + json.dumps(payload, separators=(",", ":")) + "\n\n").encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Content-Length", str(len(response_bytes)))
        self.end_headers()
        self.wfile.write(response_bytes)
        self.wfile.flush()
        self.server.handled += 1

class ObjectiveAnswerServer(HTTPServer):
    def handle_error(self, request, client_address):
        with open(config["errorPath"], "w", encoding="utf-8", newline="") as handle:
            traceback.print_exc(file=handle)

server = None
try:
    server = ObjectiveAnswerServer(("127.0.0.1", int(config["port"])), ObjectiveAnswerHandler)
    server.timeout = 0.05
    server.handled = 0
    with open(config["readyPath"], "w", encoding="utf-8", newline="") as handle:
        handle.write("ready")
    while server.handled < int(config["requestCount"]) and not os.path.exists(config["stopPath"]):
        server.handle_request()
except Exception:
    with open(config["errorPath"], "w", encoding="utf-8", newline="") as handle:
        traceback.print_exc(file=handle)
    raise
finally:
    if server is not None:
        server.server_close()
'@
  $scriptEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serverScript.Replace('__OBJECTIVE_SERVER_CONFIG__', $configEncoded)))
  $python = Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = [string]$python.Source
  $startInfo.Arguments = '-c "import base64;exec(compile(base64.b64decode(''' + $scriptEncoded + '''),''<objective-answer-sse-server>'',''exec''))"'
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'Objective answer test SSE server process did not start.' }
  $deadline = (Get-Date).AddSeconds(10)
  while (-not (Test-Path -LiteralPath $readyPath) -and (Get-Date) -lt $deadline -and -not $process.HasExited) { Start-Sleep -Milliseconds 50 }
  if (-not (Test-Path -LiteralPath $readyPath)) {
    if (-not $process.HasExited) { try { $process.Kill() } catch {} }
    $process.WaitForExit()
    $details = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $exitCode = $process.ExitCode
    $process.Dispose()
    throw "Objective answer test SSE server failed to start: exitCode=$exitCode details=$details"
  }
  return [pscustomobject]@{ process=$process; url=$prefix; requestPath=$requestPath; stopPath=$stopPath; errorPath=$errorPath }
}

function Wait-ObjectiveGeneratorSseServer($Server,[int]$TimeoutSeconds=5) {
  if ($null -eq $Server -or $null -eq $Server.process) { return 'Missing' }
  if (-not $Server.process.WaitForExit($TimeoutSeconds * 1000)) { return 'Running' }
  if ($Server.process.ExitCode -ne 0) {
    $details = $Server.process.StandardOutput.ReadToEnd() + $Server.process.StandardError.ReadToEnd()
    throw "Objective answer test SSE server failed: exitCode=$($Server.process.ExitCode) details=$details"
  }
  return 'Completed'
}

function Stop-ObjectiveGeneratorSseServer($Server) {
  if ($null -eq $Server) { return }
  if ($Server.PSObject.Properties['stopPath']) {
    try { [IO.File]::WriteAllText([string]$Server.stopPath, 'stop', [Text.UTF8Encoding]::new($false)) } catch {}
  }
  if ($Server.PSObject.Properties['process'] -and $null -ne $Server.process) {
    try {
      if (-not $Server.process.HasExited -and -not $Server.process.WaitForExit(5000)) { $Server.process.Kill(); $Server.process.WaitForExit() }
    } finally {
      $Server.process.Dispose()
    }
  }
  if ($Server.PSObject.Properties['errorPath'] -and (Test-Path -LiteralPath $Server.errorPath)) {
    throw "Objective answer test SSE server failed: $([IO.File]::ReadAllText([string]$Server.errorPath, [Text.Encoding]::UTF8))"
  }
}

Describe 'Objective answer artifact generator' {
  It 'pins the resolved Python executable for the Responses child client' {
    $bridge = Get-Content -LiteralPath (Join-Path $root 'scripts\internal\responses-api-bridge.ps1') -Raw -Encoding UTF8
    $bridge | Should Match '\$python = Get-Command python -CommandType Application'
    $bridge | Should Match '\$raw = @\(& \$python\.Source \$client'
    $bridge | Should Match '\$startInfo\.FileName = \[string\]\$python\.Source'
    $bridge | Should Not Match "\$startInfo\.FileName = 'python'"
  }

  It 'passes response credentials through the private stdin envelope' {
    $bridge = Get-Content -LiteralPath (Join-Path $root 'scripts\internal\responses-api-bridge.ps1') -Raw -Encoding UTF8
    $bridge | Should Match '--stdin-envelope'
    $bridge | Should Match 'apiKey = \$ApiKey'
    $bridge | Should Not Match 'EnvironmentVariables'
    $bridge | Should Not Match 'SUPER_BRAIN_RESPONSE_CLIENT_API_KEY'
  }

  It 'keeps the local Codex Responses route on native SSE negotiation' {
    $client = Get-Content -LiteralPath (Join-Path $root 'runtime\responses_api_client.py') -Raw -Encoding UTF8
    $client | Should Match 'headers\["Accept"\] = "text/event-stream"'
    $client | Should Match 'headers\["OpenAI-Beta"\] = "responses=v1"'
    $client | Should Not Match 'headers\["Accept"\] = "application/json"'
  }

  It 'uses freeform JSON instead of json_schema on the local Codex route' {
    $bridge = Get-Content -LiteralPath (Join-Path $root 'scripts\internal\responses-api-bridge.ps1') -Raw -Encoding UTF8
    $bridge | Should Match '\$null -ne \$JsonSchema -and -not \(Test-SuperBrainLocalCodexResponsesEndpoint \$Uri\)'
  }

  It 'checkpoints intentional batch boundaries and resumes only unsent batches' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'checkpoint-resume'
    $inputPath = Join-Path $runRoot 'input.json'
    $outputPath = Join-Path $runRoot 'answers.json'
    Write-ObjectiveGeneratorTestJson $inputPath (New-ObjectiveGeneratorInput -Enabled $true -CaseCount 2 -BatchSize 1)
    $server = Start-ObjectiveGeneratorSseServer -RequestCount 3
    $env:SUPER_BRAIN_TEST_OBJECTIVE_KEY = 'test-objective-key'
    try {
      Assert-ObjectiveGeneratorSucceeded (Invoke-ObjectiveGenerator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')) 'checkpoint_probe'
      $partial = Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-AnswerInputPath',$inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-BatchSize','1','-MaxNewBatches','1','-Json')
      Assert-ObjectiveGeneratorSucceeded $partial 'checkpoint_partial'
      $partial.value.status | Should Be 'checkpointed_partial'
      $partial.value.completedBatchCount | Should Be 1
      $checkpointPath = [string]$partial.value.checkpointPath
      Test-Path -LiteralPath $checkpointPath | Should Be $true
      Test-Path -LiteralPath $outputPath | Should Be $false
      $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $checkpoint.status | Should Be 'active'
      $checkpoint.batches[0].status | Should Be 'complete'
      $checkpoint.batches[1].status | Should Be 'pending'
      $resumed = Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-Resume','-AnswerInputPath',$inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-BatchSize','1','-Json')
      Assert-ObjectiveGeneratorSucceeded $resumed 'checkpoint_resume'
      $resumed.value.resumed | Should Be $true
      $resumed.value.batchCount | Should Be 2
      $artifact = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
      @($artifact.cases).Count | Should Be 2
      $artifact.generator.responseAttemptCount | Should Be 2
      (Wait-ObjectiveGeneratorSseServer $server 3) | Should Be 'Completed'
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_OBJECTIVE_KEY -ErrorAction SilentlyContinue
      Stop-ObjectiveGeneratorSseServer $server
    }
  }

  It 'fails closed instead of replaying an indeterminate batch' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'checkpoint-indeterminate'
    $inputPath = Join-Path $runRoot 'input.json'
    $outputPath = Join-Path $runRoot 'answers.json'
    Write-ObjectiveGeneratorTestJson $inputPath (New-ObjectiveGeneratorInput -Enabled $true -CaseCount 2 -BatchSize 1)
    $server = Start-ObjectiveGeneratorSseServer -RequestCount 2
    $env:SUPER_BRAIN_TEST_OBJECTIVE_KEY = 'test-objective-key'
    try {
      Assert-ObjectiveGeneratorSucceeded (Invoke-ObjectiveGenerator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')) 'indeterminate_probe'
      $partial = Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-AnswerInputPath',$inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-BatchSize','1','-MaxNewBatches','1','-Json')
      Assert-ObjectiveGeneratorSucceeded $partial 'indeterminate_partial'
      $checkpointPath = [string]$partial.value.checkpointPath
      $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $checkpoint.batches[1].status = 'in_progress'
      $checkpoint.batches[1].attemptCount = 1
      [IO.File]::WriteAllText($checkpointPath, ($checkpoint | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
      $resume = Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-Resume','-AnswerInputPath',$inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-BatchSize','1','-Json')
      $resume.exitCode | Should Be 1
      $resume.value.code | Should Be 'OBJECTIVE_CHECKPOINT_INDETERMINATE'
      (Wait-ObjectiveGeneratorSseServer $server 3) | Should Be 'Completed'
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_OBJECTIVE_KEY -ErrorAction SilentlyContinue
      Stop-ObjectiveGeneratorSseServer $server
    }
  }

  It 'generates one private treatment artifact without sending reference or rubric to the model' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'treatment-artifact'
    $inputPath = Join-Path $runRoot 'input.json'
    $outputPath = Join-Path $runRoot 'answers.json'
    $reference = 'OBJECTIVE_REFERENCE_SENTINEL_NEVER_SEND'
    Write-ObjectiveGeneratorTestJson $inputPath (New-ObjectiveGeneratorInput $true $reference)
    $server = Start-ObjectiveGeneratorSseServer -RequestCount 2
    $env:SUPER_BRAIN_TEST_OBJECTIVE_KEY = 'test-objective-key'
    try {
      $preflight = Invoke-ObjectiveGenerator @('-Action','Preflight','-AnswerInputPath',$inputPath,'-Json')
      $preflight.exitCode | Should Be 0
      $preflight.value.status | Should Be 'preflight_ok'
      $preflight.value.benchmarkVariant | Should Be 's_cleaned'
      Assert-ObjectiveGeneratorSucceeded (Invoke-ObjectiveGenerator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')) 'treatment_probe'
      $result = Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-AnswerInputPath',$inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')
      $result.exitCode | Should Be 0
      $result.value.status | Should Be 'generated_private_artifact'
      $result.value.superMemoryBrainEnabled | Should Be $true
      $artifact = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $artifact.schema | Should Be 'super-brain.objective-answer-artifact.v1'
      $artifact.generator.benchmarkVariant | Should Be 's_cleaned'
      $artifact.generator.superMemoryBrainEnabled | Should Be $true
      $artifact.generator.rawResponseStored | Should Be $false
      $artifact.generator.referenceOrRubricSentToModel | Should Be $false
      $artifact.generator.responseModelEvidenceSha256 | Should Be (Get-ObjectiveTestHash "case-1`ngpt-5.6-terra")
      @($artifact.cases).Count | Should Be 1
      $artifact.cases[0].answer | Should Be 'red'
      $requestText = Get-Content -LiteralPath $server.requestPath -Raw -Encoding UTF8
      $requestText | Should Not Match $reference
      $requestText | Should Not Match 'Answer with the selected color.'
      $requestText | Should Match 'Retrieved context says the answer is red.'
      ($requestText | ConvertFrom-Json).input -is [string] | Should Be $true
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_OBJECTIVE_KEY -ErrorAction SilentlyContinue
      Stop-ObjectiveGeneratorSseServer $server
    }
  }

  It 'rejects non-empty baseline memory before network generation' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'baseline-reject'
    $inputPath = Join-Path $runRoot 'input.json'
    $invalid = New-ObjectiveGeneratorInput $false
    $invalid.cases[0].retrievedContext = 'This must not enter the baseline.'
    Write-ObjectiveGeneratorTestJson $inputPath $invalid
    $result = Invoke-ObjectiveGenerator @('-Action','Preflight','-AnswerInputPath',$inputPath,'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'OBJECTIVE_BASELINE_CONTEXT_NOT_EMPTY'
  }

  It 'fails closed when the shared pair contract is changed after input preparation' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'pair-contract-tamper'
    $inputPath = Join-Path $runRoot 'input.json'
    Write-ObjectiveGeneratorTestJson $inputPath (New-ObjectiveGeneratorInput $true)
    $input = Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    [IO.File]::AppendAllText([string]$input.pairContract.path, "`n", [Text.UTF8Encoding]::new($false))
    $result = Invoke-ObjectiveGenerator @('-Action','Preflight','-AnswerInputPath',$inputPath,'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'OBJECTIVE_PAIR_CONTRACT_TAMPERED'
  }

  It 'requires explicit Apply and rejects public package output paths' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'apply-and-private'
    $inputPath = Join-Path $runRoot 'input.json'
    Write-ObjectiveGeneratorTestJson $inputPath (New-ObjectiveGeneratorInput $false)
    $noApply = Invoke-ObjectiveGenerator @('-Action','Generate','-AnswerInputPath',$inputPath,'-OutputPath',(Join-Path $runRoot 'answers.json'),'-Json')
    $noApply.exitCode | Should Be 1
    $noApply.value.code | Should Be 'GENERATE_APPLY_REQUIRED'
    $publicPath = Join-Path $root ('objective-generator-public-test-' + [guid]::NewGuid().ToString('N') + '.json')
    $public = Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-AnswerInputPath',$inputPath,'-OutputPath',$publicPath,'-Json')
    $public.exitCode | Should Be 1
    $public.value.code | Should Be 'OBJECTIVE_OUTPUT_NOT_PRIVATE'
    Test-Path -LiteralPath $publicPath | Should Be $false
  }

  It 'normalizes scalar input only for the local Codex Responses route' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'codex-local-input-shape'
    $inputPath = Join-Path $runRoot 'input.json'
    $outputPath = Join-Path $runRoot 'answers.json'
    Write-ObjectiveGeneratorTestJson $inputPath (New-ObjectiveGeneratorInput $false)
    $server = Start-ObjectiveGeneratorSseServer -RoutePath 'codex/v1/responses' -RequestCount 2
    $env:SUPER_BRAIN_TEST_OBJECTIVE_KEY = 'test-objective-key'
    try {
      Assert-ObjectiveGeneratorSucceeded (Invoke-ObjectiveGenerator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')) 'local_codex_probe'
      $result = Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-AnswerInputPath',$inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')
      $result.exitCode | Should Be 0
      $request = Get-Content -LiteralPath $server.requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
      ($request.input -is [array]) | Should Be $true
      @($request.input).Count | Should Be 1
      $request.input[0].type | Should Be 'message'
      $request.input[0].role | Should Be 'user'
      $request.input[0].content[0].type | Should Be 'input_text'
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_OBJECTIVE_KEY -ErrorAction SilentlyContinue
      Stop-ObjectiveGeneratorSseServer $server
    }
  }

  It 'produces distinct comparable baseline and treatment artifacts for the blind runner' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'paired-artifacts'
    $baselineInput = Join-Path $runRoot 'baseline-input.json'
    $treatmentInput = Join-Path $runRoot 'treatment-input.json'
    $baselineOutput = Join-Path $runRoot 'baseline-answers.json'
    $treatmentOutput = Join-Path $runRoot 'treatment-answers.json'
    $statePath = Join-Path $runRoot 'blind-state.json'
    $judgeInputPath = Join-Path $runRoot 'judge-input.json'
    Write-ObjectiveGeneratorTestJson $baselineInput (New-ObjectiveGeneratorInput $false)
    Write-ObjectiveGeneratorTestJson $treatmentInput (New-ObjectiveGeneratorInput $true)
    $server = Start-ObjectiveGeneratorSseServer -RequestCount 3
    $env:SUPER_BRAIN_TEST_OBJECTIVE_KEY = 'test-objective-key'
    try {
      Assert-ObjectiveGeneratorSucceeded (Invoke-ObjectiveGenerator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')) 'paired_probe'
      (Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-AnswerInputPath',$baselineInput,'-OutputPath',$baselineOutput,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')).exitCode | Should Be 0
      (Invoke-ObjectiveGenerator @('-Action','Generate','-Apply','-AnswerInputPath',$treatmentInput,'-OutputPath',$treatmentOutput,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_OBJECTIVE_KEY','-TimeoutSeconds','30','-Json')).exitCode | Should Be 0
      $prepared = Invoke-ObjectiveBlindRunner @('-Action','Prepare','-BaselinePath',$baselineOutput,'-TreatmentPath',$treatmentOutput,'-StatePath',$statePath,'-JudgeInputPath',$judgeInputPath,'-JudgeModel','gpt-5.6-luna','-JudgeReasoningEffort','max','-Json')
      if ($prepared.exitCode -ne 0) { throw "OBJECTIVE_BLIND_RUNNER_STAGE_FAILED code=$($prepared.value.code) error=$($prepared.value.error)" }
      $prepared.exitCode | Should Be 0
      $prepared.value.status | Should Be 'awaiting_judge'
      $prepared.value.caseCount | Should Be 1
      $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $state.baselineArtifact.generator.executionId | Should Not Be $state.treatmentArtifact.generator.executionId
      $state.baselineArtifact.generator.configFingerprint | Should Be $state.treatmentArtifact.generator.configFingerprint
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_OBJECTIVE_KEY -ErrorAction SilentlyContinue
      Stop-ObjectiveGeneratorSseServer $server
    }
  }

  It 'exports isolated native batches and rebuilds comparable paired artifacts locally' {
    $runRoot = Join-Path (Get-ObjectiveTestDrivePath) 'native-paired-artifacts'
    $baselineInput = Join-Path $runRoot 'baseline-input.json'
    $treatmentInput = Join-Path $runRoot 'treatment-input.json'
    $baselineManifest = Join-Path $runRoot 'baseline-native-manifest.json'
    $treatmentManifest = Join-Path $runRoot 'treatment-native-manifest.json'
    $baselineResponses = Join-Path $runRoot 'baseline-native-responses'
    $treatmentResponses = Join-Path $runRoot 'treatment-native-responses'
    $baselineOutput = Join-Path $runRoot 'baseline-native-answers.json'
    $treatmentOutput = Join-Path $runRoot 'treatment-native-answers.json'
    $statePath = Join-Path $runRoot 'native-blind-state.json'
    $judgeInputPath = Join-Path $runRoot 'native-judge-input.json'
    Write-ObjectiveGeneratorTestJson $baselineInput (New-ObjectiveGeneratorInput $false -CaseCount 2 -BatchSize 1)
    Write-ObjectiveGeneratorTestJson $treatmentInput (New-ObjectiveGeneratorInput $true -CaseCount 2 -BatchSize 1)
    $arms = @(
      [pscustomobject]@{ name='baseline'; input=$baselineInput; manifest=$baselineManifest; responses=$baselineResponses; output=$baselineOutput },
      [pscustomobject]@{ name='treatment'; input=$treatmentInput; manifest=$treatmentManifest; responses=$treatmentResponses; output=$treatmentOutput }
    )
    $artifacts = @{}
    foreach ($arm in $arms) {
      $export = Invoke-ObjectiveGenerator @('-Action','ExportNative','-Apply','-AnswerInputPath',$arm.input,'-OutputPath',$arm.manifest,'-BatchSize','1','-TimeoutSeconds','30','-Json')
      if ($export.exitCode -ne 0) { throw "OBJECTIVE_NATIVE_EXPORT_FAILED code=$($export.value.code) error=$($export.value.error)" }
      $export.exitCode | Should Be 0
      $export.value.status | Should Be 'native_batches_exported_private'
      $export.value.batchCount | Should Be 2
      $manifest = Get-Content -LiteralPath $arm.manifest -Raw -Encoding UTF8 | ConvertFrom-Json
      $manifest.privacy.referenceOrRubricSentToAgent | Should Be $false
      $manifest.privacy.rawExpectedDataStored | Should Be $false
      $manifestText = Get-Content -LiteralPath $arm.manifest -Raw -Encoding UTF8
      $manifestText | Should Not Match 'OBJECTIVE_REFERENCE_SENTINEL'
      $manifestText | Should Not Match 'Answer with the selected color.'
      $batchDirectory = Join-Path (Split-Path -Parent $arm.manifest) $manifest.batchDirectoryName
      foreach ($entry in @($manifest.batches)) {
        $batchText = Get-Content -LiteralPath (Join-Path $batchDirectory $entry.batchFile) -Raw -Encoding UTF8
        $batchText | Should Not Match 'OBJECTIVE_REFERENCE_SENTINEL'
        $batchText | Should Not Match 'Answer with the selected color.'
      }
      New-Item -ItemType Directory -Force -Path $arm.responses | Out-Null
      foreach ($entry in @($manifest.batches)) {
        $response = [pscustomobject]@{
          schema='super-brain.objective-host-native-agent-response.v1'
          batchId=[string]$entry.batchId
          batchHash=[string]$entry.batchHash
          hostAgentId="native-agent-$($arm.name)-$($entry.index)"
          hostDispatchId="native-dispatch-$($arm.name)-$($entry.index)"
          cases=@($entry.caseIds | ForEach-Object { [pscustomobject]@{ id=[string]$_; answer='red' } })
        }
        Write-ObjectiveGeneratorTestJson (Join-Path $arm.responses $entry.responseFile) $response
      }
      $import = Invoke-ObjectiveGenerator @('-Action','ImportNative','-Apply','-AnswerInputPath',$arm.input,'-NativeManifestPath',$arm.manifest,'-NativeResponseDirectory',$arm.responses,'-OutputPath',$arm.output,'-BatchSize','1','-TimeoutSeconds','30','-Json')
      $import.exitCode | Should Be 0
      $import.value.status | Should Be 'native_batches_imported_private'
      $artifact = Get-Content -LiteralPath $arm.output -Raw -Encoding UTF8 | ConvertFrom-Json
      $artifact.generator.hostedNativeAgent | Should Be $true
      $artifact.generator.modelIdentityVerified | Should Be $true
      $artifact.generator.referenceOrRubricSentToModel | Should Be $false
      $artifact.generator.hostDispatchReceiptSha256 | Should Match '^[0-9a-f]{64}$'
      @($artifact.cases).Count | Should Be 2
      $artifact.cases[0].reference | Should Match 'OBJECTIVE_REFERENCE_SENTINEL'
      $artifacts[$arm.name] = $artifact
    }
    $prepared = Invoke-ObjectiveBlindRunner @('-Action','Prepare','-BaselinePath',$baselineOutput,'-TreatmentPath',$treatmentOutput,'-StatePath',$statePath,'-JudgeInputPath',$judgeInputPath,'-JudgeModel','gpt-5.6-luna','-JudgeReasoningEffort','max','-Json')
    if ($prepared.exitCode -ne 0) { throw "OBJECTIVE_NATIVE_BLIND_RUNNER_STAGE_FAILED code=$($prepared.value.code) error=$($prepared.value.error)" }
    $prepared.exitCode | Should Be 0
    $prepared.value.status | Should Be 'awaiting_judge'
    $prepared.value.caseCount | Should Be 2
    $artifacts.baseline.generator.configFingerprint | Should Be $artifacts.treatment.generator.configFingerprint
    $artifacts.baseline.generator.executionId | Should Not Be $artifacts.treatment.generator.executionId
  }
}
