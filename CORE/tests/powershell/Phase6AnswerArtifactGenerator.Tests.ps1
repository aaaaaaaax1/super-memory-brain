$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$generatorPath = Join-Path $root 'scripts\phase6-answer-artifact-generator.ps1'
$phase6Path = Join-Path $root 'scripts\phase6-memory-eval.ps1'
$runnerPath = Join-Path $root 'scripts\objective-benchmark-runner.ps1'

function Write-Phase6GeneratorJson([string]$Path,$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
}

function Invoke-Phase6Generator([string[]]$Arguments) {
  $previousReceiptRoot = $env:SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT
  $env:SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT = Join-Path $TestDrive 'transport-receipts'
  try {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $generatorPath @Arguments 2>$null)
    return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=(($raw -join "`n") | ConvertFrom-Json) }
  } finally {
    if ($null -eq $previousReceiptRoot) { Remove-Item Env:\SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_TRANSPORT_RECEIPT_ROOT = $previousReceiptRoot }
  }
}

function Invoke-Phase6Wrapper([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $phase6Path @Arguments 2>$null)
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=(($raw -join "`n") | ConvertFrom-Json) }
}

function Invoke-ObjectiveRunnerStatus {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Action Status -Json 2>$null)
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=(($raw -join "`n") | ConvertFrom-Json) }
}

function Start-Phase6AnswerSseServer([string]$Model='gpt-5.6-terra',[string]$Text='{"cases":[{"id":"unknown-case","answerText":""}]}',[int]$RequestCount=1,[string]$RequestCaptureRoot='',[string]$ResponseTextsJson='',[string]$ResponseStatusCodesJson='') {
  $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  $portProbe.Start()
  $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
  $portProbe.Stop()
  $prefix = "http://127.0.0.1:$port/"
  $readyPath = Join-Path $TestDrive "phase6-answer-$port.ready"
  $job = Start-Job -ScriptBlock {
    param($Prefix,$ReadyPath,$Model,$Text,$RequestCount,$RequestCaptureRoot,$ResponseTextsJson,$ResponseStatusCodesJson)
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    try {
      $listener.Start()
      [IO.File]::WriteAllText($ReadyPath,'ready',[Text.UTF8Encoding]::new($false))
      if (-not [string]::IsNullOrWhiteSpace($RequestCaptureRoot)) { New-Item -ItemType Directory -Force -Path $RequestCaptureRoot | Out-Null }
      $responseTexts = if ([string]::IsNullOrWhiteSpace($ResponseTextsJson)) { @() } else { @($ResponseTextsJson | ConvertFrom-Json) }
      $responseStatusCodes = if ([string]::IsNullOrWhiteSpace($ResponseStatusCodesJson)) { @() } else { @($ResponseStatusCodesJson | ConvertFrom-Json) }
      for ($requestIndex = 1; $requestIndex -le $RequestCount; $requestIndex++) {
        $context = $listener.GetContext()
        if (-not [string]::IsNullOrWhiteSpace($RequestCaptureRoot)) {
          $capture = [IO.MemoryStream]::new()
          try {
            $context.Request.InputStream.CopyTo($capture)
            [IO.File]::WriteAllBytes((Join-Path $RequestCaptureRoot ("request-$requestIndex.json")),$capture.ToArray())
          } finally {
            $capture.Dispose()
          }
        }
        $statusCode = if ($requestIndex -le $responseStatusCodes.Count) { [int]$responseStatusCodes[$requestIndex - 1] } else { 200 }
        if ($statusCode -ne 200) {
          $errorBytes = [Text.Encoding]::UTF8.GetBytes('{"error":"synthetic transport failure"}')
          $context.Response.StatusCode = $statusCode
          $context.Response.ContentType = 'application/json; charset=utf-8'
          $context.Response.ContentEncoding = [Text.Encoding]::UTF8
          $context.Response.ContentLength64 = $errorBytes.Length
          $context.Response.OutputStream.Write($errorBytes,0,$errorBytes.Length)
          $context.Response.Close()
          continue
        }
        $responseText = if ($requestIndex -le $responseTexts.Count) { [string]$responseTexts[$requestIndex - 1] } else { $Text }
        $payload = [pscustomobject]@{
          type = 'response.completed'
          response = [pscustomobject]@{
            id = "phase6-response-test-$requestIndex"
            object = 'response'
            model = $Model
            status = 'completed'
            output = @([pscustomobject]@{ type='message'; content=@([pscustomobject]@{ type='output_text'; text=$responseText }) })
          }
        } | ConvertTo-Json -Depth 12 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes("event: response.completed`n" + "data: $payload`n`n")
        $context.Response.StatusCode = 200
        $context.Response.ContentType = 'text/event-stream; charset=utf-8'
        $context.Response.ContentEncoding = [Text.Encoding]::UTF8
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.Headers['Cache-Control'] = 'no-cache'
        $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
        $context.Response.Close()
      }
    } finally {
      if ($listener.IsListening) { $listener.Stop() }
      $listener.Close()
    }
  } -ArgumentList $prefix,$readyPath,$Model,$Text,$RequestCount,$RequestCaptureRoot,$ResponseTextsJson,$ResponseStatusCodesJson
  $deadline = (Get-Date).AddSeconds(10)
  while (-not (Test-Path -LiteralPath $readyPath) -and (Get-Date) -lt $deadline -and $job.State -notin @('Failed','Completed','Stopped')) { Start-Sleep -Milliseconds 50 }
  if (-not (Test-Path -LiteralPath $readyPath)) {
    $details = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue | Out-String
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    throw "Phase 6 test SSE server failed to start: $details"
  }
  return [pscustomobject]@{ job=$job; url=$prefix; requestCaptureRoot=$RequestCaptureRoot }
}

function Stop-Phase6AnswerSseServer($Server) {
  if ($null -eq $Server) { return }
  Wait-Job -Job $Server.job -Timeout 5 | Out-Null
  Stop-Job -Job $Server.job -ErrorAction SilentlyContinue
  Remove-Job -Job $Server.job -Force -ErrorAction SilentlyContinue
}

function New-Phase6CheckpointTestInput([string]$RunRoot) {
  New-Item -ItemType Directory -Force -Path $RunRoot | Out-Null
  $sourcePath = Join-Path $RunRoot 'source.json'
  $sealedPath = Join-Path $RunRoot 'sealed.json'
  $inputPath = Join-Path $RunRoot 'private-input.json'
  $source = [pscustomobject]@{
    schema = 'super-brain.memory-e2e-source.v1'
    setId = 'phase6-checkpoint-test'
    cases = @(
      [pscustomobject]@{
        id = 'known-case'
        familyId = 'known-family'
        category = 'information_extraction'
        records = @([pscustomobject]@{ id='known-evidence'; text='[CURRENT][VERIFIED] Known test value is known-42.'; layer='project' })
        query = 'What is the known test value?'
        expected = [pscustomobject]@{ evidenceIds=@('known-evidence'); answer=[pscustomobject]@{ mode='answer'; requiredPhrases=@('known-42') } }
      },
      [pscustomobject]@{
        id = 'unknown-case'
        familyId = 'unknown-family'
        category = 'unsupported_unknown'
        records = @([pscustomobject]@{ id='private-evidence'; text='[CURRENT][VERIFIED] This evidence does not contain the requested value.'; layer='project' })
        query = 'What unavailable value should be returned?'
        expected = [pscustomobject]@{ evidenceIds=@(); answer=[pscustomobject]@{ mode='abstain'; requiredPhrases=@() } }
      }
    )
  }
  Write-Phase6GeneratorJson $sourcePath $source
  (Invoke-Phase6Wrapper @('-Action','Seal','-SourcePath',$sourcePath,'-OutputPath',$sealedPath,'-Json')).exitCode | Should Be 0
  (Invoke-Phase6Wrapper @('-Action','PrepareAnswerInput','-SealedPath',$sealedPath,'-OutputPath',$inputPath,'-Json')).exitCode | Should Be 0
  return [pscustomobject]@{ sourcePath=$sourcePath; sealedPath=$sealedPath; inputPath=$inputPath }
}

Describe 'Phase 6 external answer artifact generator' {
  It 'prefers a complete explicit Super Brain endpoint, then the current Codex text provider' {
    $originalCodexHome = $env:CODEX_HOME
    $originalAnswerUrl = $env:SUPER_BRAIN_ANSWER_RESPONSES_URL
    $originalAnswerKey = $env:SUPER_BRAIN_ANSWER_API_KEY
    $testHome = Join-Path $TestDrive 'codex-provider-home'
    $configPath = Join-Path $testHome 'config.toml'
    New-Item -ItemType Directory -Force -Path $testHome | Out-Null
    [IO.File]::WriteAllText($configPath,@"
model_provider = "custom"
[model_providers.custom]
base_url = "http://127.0.0.1:18883/v1"
experimental_bearer_token = "test-codex-bearer"
wire_api = "responses"
"@,[Text.UTF8Encoding]::new($false))
    $env:CODEX_HOME = $testHome
    $env:SUPER_BRAIN_ANSWER_RESPONSES_URL = 'https://explicit.example.test/v1/responses'
    $env:SUPER_BRAIN_ANSWER_API_KEY = 'test-explicit-key'
    . (Join-Path $root 'scripts\internal\responses-api-bridge.ps1')
    try {
      $explicit = Resolve-SuperBrainResponsesConnection -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_ANSWER_RESPONSES_URL' -ApiKeyEnvironment 'SUPER_BRAIN_ANSWER_API_KEY'
      $explicit.configured | Should Be $true
      $explicit.endpointSource | Should Be 'super_brain_environment'
      $explicit.credentialSource | Should Be 'super_brain_environment'

      Remove-Item Env:\SUPER_BRAIN_ANSWER_RESPONSES_URL -ErrorAction SilentlyContinue
      Remove-Item Env:\SUPER_BRAIN_ANSWER_API_KEY -ErrorAction SilentlyContinue
      $codex = Resolve-SuperBrainResponsesConnection -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_ANSWER_RESPONSES_URL' -ApiKeyEnvironment 'SUPER_BRAIN_ANSWER_API_KEY'
      $codex.configured | Should Be $true
      $codex.endpointSource | Should Be 'codex_desktop_config'
      $codex.credentialSource | Should Be 'codex_desktop_config'
      $codex.responsesUrl | Should Be 'http://127.0.0.1:18883/v1/responses'
    } finally {
      if ($null -eq $originalCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $originalCodexHome }
      if ($null -eq $originalAnswerUrl) { Remove-Item Env:\SUPER_BRAIN_ANSWER_RESPONSES_URL -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ANSWER_RESPONSES_URL = $originalAnswerUrl }
      if ($null -eq $originalAnswerKey) { Remove-Item Env:\SUPER_BRAIN_ANSWER_API_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ANSWER_API_KEY = $originalAnswerKey }
    }
  }

  It 'fails closed when an explicit endpoint has no matching credential' {
    $originalCodexHome = $env:CODEX_HOME
    $originalAnswerUrl = $env:SUPER_BRAIN_ANSWER_RESPONSES_URL
    $originalAnswerKey = $env:SUPER_BRAIN_ANSWER_API_KEY
    $env:CODEX_HOME = Join-Path $TestDrive 'missing-codex-provider-home'
    $env:SUPER_BRAIN_ANSWER_RESPONSES_URL = 'https://explicit.example.test/v1/responses'
    Remove-Item Env:\SUPER_BRAIN_ANSWER_API_KEY -ErrorAction SilentlyContinue
    . (Join-Path $root 'scripts\internal\responses-api-bridge.ps1')
    try {
      $connection = Resolve-SuperBrainResponsesConnection -PrimaryResponsesUrlEnvironment 'SUPER_BRAIN_ANSWER_RESPONSES_URL' -ApiKeyEnvironment 'SUPER_BRAIN_ANSWER_API_KEY'
      $connection.configured | Should Be $false
      $connection.endpointSource | Should Be 'super_brain_environment'
      $connection.credentialSource | Should Be 'none'
      $connection.resolutionCode | Should Be 'RESPONSES_API_KEY_MISSING'
    } finally {
      if ($null -eq $originalCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $originalCodexHome }
      if ($null -eq $originalAnswerUrl) { Remove-Item Env:\SUPER_BRAIN_ANSWER_RESPONSES_URL -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ANSWER_RESPONSES_URL = $originalAnswerUrl }
      if ($null -eq $originalAnswerKey) { Remove-Item Env:\SUPER_BRAIN_ANSWER_API_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ANSWER_API_KEY = $originalAnswerKey }
    }
  }

  It 'uses a managed Smag credential cache only as a fallback without exposing a key' {
    $originalCodexHome = $env:CODEX_HOME
    $originalJudgeKey = $env:SUPER_BRAIN_JUDGE_API_KEY
    $testHome = Join-Path $TestDrive 'codex-home'
    $cachePath = Join-Path $testHome 'secrets\smag.local.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cachePath) | Out-Null
    [IO.File]::WriteAllText($cachePath,'{"base_url":"https://example.test/v1","api_key":"managed-test-key"}',[Text.UTF8Encoding]::new($false))
    Remove-Item Env:\SUPER_BRAIN_JUDGE_API_KEY -ErrorAction SilentlyContinue
    $env:CODEX_HOME = $testHome
    try {
      $result = Invoke-ObjectiveRunnerStatus
      $result.exitCode | Should Be 0
      $result.value.status | Should Be 'configured_unverified'
      $result.value.endpointSource | Should Be 'smag_managed_cache'
      $result.value.credentialSource | Should Be 'smag_managed_cache'
      (($result.value | ConvertTo-Json -Depth 10) -match 'managed-test-key') | Should Be $false
    } finally {
      if ($null -eq $originalCodexHome) { Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $originalCodexHome }
      if ($null -eq $originalJudgeKey) { Remove-Item Env:\SUPER_BRAIN_JUDGE_API_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_JUDGE_API_KEY = $originalJudgeKey }
    }
  }

  It 'preserves UTF-8 request text through the private Responses child transport' {
    $requestCaptureRoot = Join-Path $TestDrive 'utf8-bridge-request-capture'
    $responseMarker = '中文响应校验-阶段6'
    $server = Start-Phase6AnswerSseServer -Text $responseMarker -RequestCount 1 -RequestCaptureRoot $requestCaptureRoot
    $marker = '中文传输校验-阶段6'
    . (Join-Path $root 'scripts\internal\responses-api-bridge.ps1')
    try {
      $result = Invoke-SuperBrainResponsesRequest -Uri $server.url -ApiKey 'test-answer-key' -Model 'gpt-5.6-terra' -ReasoningEffort 'max' -RequestInput $marker -MaxOutputTokens 64 -TimeoutSeconds 30
      $result.reportedModel | Should Be 'gpt-5.6-terra'
      (Get-SuperBrainResponsesText $result.response) | Should Be $responseMarker
      $request = Get-Content -LiteralPath (Join-Path $requestCaptureRoot 'request-1.json') -Raw -Encoding UTF8
      ($request.IndexOf($marker,[StringComparison]::Ordinal) -ge 0) | Should Be $true
    } finally {
      Stop-Phase6AnswerSseServer $server
    }
  }

  It 'preflights a blinded input then writes a private external artifact without raw evidence' {
    $runRoot = Join-Path $TestDrive 'generated-artifact'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $sourcePath = Join-Path $runRoot 'source.json'
    $sealedPath = Join-Path $runRoot 'sealed.json'
    $inputPath = Join-Path $runRoot 'private-input.json'
    $artifactPath = Join-Path $runRoot 'answers.json'
    $sentinel = 'PHASE6_PRIVATE_EVIDENCE_SENTINEL'
    $source = [pscustomobject]@{
      schema = 'super-brain.memory-e2e-source.v1'
      setId = 'phase6-generator-test'
      cases = @([pscustomobject]@{
        id = 'unknown-case'
        familyId = 'unknown-family'
        category = 'unsupported_unknown'
        records = @([pscustomobject]@{ id='private-evidence'; text=$sentinel; layer='project' })
        query = 'What is not present in this evidence?'
        expected = [pscustomobject]@{ evidenceIds=@(); answer=[pscustomobject]@{ mode='abstain'; requiredPhrases=@() } }
      },[pscustomobject]@{
        id = 'known-case'
        familyId = 'known-family'
        category = 'information_extraction'
        records = @([pscustomobject]@{ id='known-evidence'; text='[CURRENT][VERIFIED] Known test value is known-42.'; layer='project' })
        query = 'What is the known test value?'
        expected = [pscustomobject]@{ evidenceIds=@('known-evidence'); answer=[pscustomobject]@{ mode='answer'; requiredPhrases=@('known-42') } }
      })
    }
    Write-Phase6GeneratorJson $sourcePath $source
    (Invoke-Phase6Wrapper @('-Action','Seal','-SourcePath',$sourcePath,'-OutputPath',$sealedPath,'-Json')).exitCode | Should Be 0
    (Invoke-Phase6Wrapper @('-Action','PrepareAnswerInput','-SealedPath',$sealedPath,'-OutputPath',$inputPath,'-Json')).exitCode | Should Be 0
    $wrappedAnswer = 'Answer:' + [Environment]::NewLine + '```json' + [Environment]::NewLine + '{"cases":[{"id":"unknown-case","answerText":"Insufficient evidence to answer."},{"id":"known-case","answerText":"known-42"}]}' + [Environment]::NewLine + '```'
    $requestCaptureRoot = Join-Path $TestDrive 'phase6-answer-request-capture'
    $server = Start-Phase6AnswerSseServer 'gpt-5.6-terra' $wrappedAnswer 2 $requestCaptureRoot
    $env:SUPER_BRAIN_TEST_ANSWER_KEY = 'test-answer-key'
    try {
      $preflight = Invoke-Phase6Generator @('-Action','Preflight','-AnswerInputPath',$inputPath,'-Json')
      $preflight.exitCode | Should Be 0
      $preflight.value.status | Should Be 'preflight_ok'
      $probe = Invoke-Phase6Generator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-Json')
      $probe.exitCode | Should Be 0
      $probe.value.transportProbeReceiptSha256 | Should Match '^[0-9a-f]{64}$'
      $probeRequest = Get-Content -LiteralPath (Join-Path $requestCaptureRoot 'request-1.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $probeRequest.stream | Should Be $true
      $probeRequest.max_output_tokens | Should Be 4096
      $probeRequest.text.format.type | Should Be 'json_schema'
      $probeRequest.text.format.schema.properties.cases.minItems | Should Be 1
      $result = Invoke-Phase6Generator @('-Action','Generate','-Apply','-AnswerInputPath',$inputPath,'-OutputPath',$artifactPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-Json')
      $result.exitCode | Should Be 0
      $result.value.status | Should Be 'generated_private_artifact'
      $artifact = Get-Content -LiteralPath $artifactPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $artifact.provenance.schema | Should Be 'super-brain.memory-e2e-answer-provenance.v2'
      $artifact.provenance.modelVersion | Should Be 'gpt-5.6-terra'
      $artifact.provenance.rawResponseStored | Should Be $false
      @($artifact.cases).Count | Should Be 2
      $unknown = @($artifact.cases | Where-Object { $_.id -eq 'unknown-case' })[0]
      $known = @($artifact.cases | Where-Object { $_.id -eq 'known-case' })[0]
      $unknown.responseModel | Should Be 'gpt-5.6-terra'
      $unknown.abstained | Should Be $true
      $unknown.claimCount | Should Be 0
      $known.abstained | Should Be $false
      $known.claimCount | Should Be 1
      @($known.claims[0].evidenceIds).Count | Should Be 1
      $known.claims[0].evidenceIds[0] | Should Be 'known-evidence'
      ((Get-Content -LiteralPath $artifactPath -Raw -Encoding UTF8) -match $sentinel) | Should Be $false
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_ANSWER_KEY -ErrorAction SilentlyContinue
      Stop-Phase6AnswerSseServer $server
    }
  }

  It 'rejects a reply whose reported model does not match the requested model' {
    $server = Start-Phase6AnswerSseServer 'unexpected-model'
    $env:SUPER_BRAIN_TEST_ANSWER_KEY = 'test-answer-key'
    try {
      $result = Invoke-Phase6Generator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-Json')
      $result.exitCode | Should Be 1
      $result.value.code | Should Be 'RESPONSES_REPORTED_MODEL_MISMATCH'
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_ANSWER_KEY -ErrorAction SilentlyContinue
      Stop-Phase6AnswerSseServer $server
    }
  }

  It 'retries a retryable synthetic transport failure before accepting a probe receipt' {
    $requestCaptureRoot = Join-Path $TestDrive 'probe-retry-capture'
    $statusCodes = @(502,200) | ConvertTo-Json -Compress
    $server = Start-Phase6AnswerSseServer -RequestCount 2 -RequestCaptureRoot $requestCaptureRoot -ResponseStatusCodesJson $statusCodes
    $env:SUPER_BRAIN_TEST_ANSWER_KEY = 'test-answer-key'
    try {
      $probe = Invoke-Phase6Generator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-ProbeMaxAttempts','2','-ProbeRetryDelayMilliseconds','0','-Json')
      $probe.exitCode | Should Be 0
      $probe.value.status | Should Be 'reachable'
      $probe.value.probeAttemptCount | Should Be 2
      $probe.value.transportRetryCount | Should Be 1
      $probe.value.transportProbeReceiptSha256 | Should Match '^[0-9a-f]{64}$'
      @(Get-ChildItem -LiteralPath $requestCaptureRoot -Filter 'request-*.json').Count | Should Be 2
      Wait-Job -Job $server.job -Timeout 3 | Out-Null
      $server.job.State | Should Be 'Completed'
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_ANSWER_KEY -ErrorAction SilentlyContinue
      Stop-Phase6AnswerSseServer $server
    }
  }

  It 'checkpoints an intentional boundary and resumes only unsent Phase 6 batches' {
    $runRoot = Join-Path $TestDrive 'checkpoint-resume'
    $input = New-Phase6CheckpointTestInput $runRoot
    $outputPath = Join-Path $runRoot 'answers.json'
    $requestCaptureRoot = Join-Path $runRoot 'request-capture'
    $responseTexts = @(
      '{"cases":[{"id":"transport-probe","answerText":"probe-ok"}]}',
      '{"cases":[{"id":"known-case","answerText":"known-42"}]}',
      '{"cases":[{"id":"unknown-case","answerText":""}]}'
    ) | ConvertTo-Json -Compress
    $server = Start-Phase6AnswerSseServer -RequestCount 3 -RequestCaptureRoot $requestCaptureRoot -ResponseTextsJson $responseTexts
    $env:SUPER_BRAIN_TEST_ANSWER_KEY = 'test-answer-key'
    try {
      $probe = Invoke-Phase6Generator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-Json')
      $probe.exitCode | Should Be 0
      $partial = Invoke-Phase6Generator @('-Action','Generate','-Apply','-AnswerInputPath',$input.inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-BatchSize','1','-MaxNewBatches','1','-Json')
      $partial.exitCode | Should Be 0
      $partial.value.status | Should Be 'checkpointed_partial'
      $partial.value.completedBatchCount | Should Be 1
      $partial.value.remainingBatchCount | Should Be 1
      $checkpointPath = [string]$partial.value.checkpointPath
      Test-Path -LiteralPath $checkpointPath | Should Be $true
      Test-Path -LiteralPath $outputPath | Should Be $false
      $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $checkpoint.status | Should Be 'active'
      $checkpoint.batches[0].status | Should Be 'complete'
      $checkpoint.batches[1].status | Should Be 'pending'
      (Get-Content -LiteralPath (Join-Path $requestCaptureRoot 'request-2.json') -Raw -Encoding UTF8) | Should Match 'Case id: known-case'
      (Get-Content -LiteralPath (Join-Path $requestCaptureRoot 'request-2.json') -Raw -Encoding UTF8) | Should Not Match 'Case id: unknown-case'

      $resumed = Invoke-Phase6Generator @('-Action','Generate','-Apply','-Resume','-AnswerInputPath',$input.inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-BatchSize','1','-Json')
      $resumed.exitCode | Should Be 0
      $resumed.value.status | Should Be 'generated_private_artifact'
      $resumed.value.resumed | Should Be $true
      $resumed.value.batchCount | Should Be 2
      $artifact = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $artifact.provenance.responseAttemptCount | Should Be 2
      @($artifact.cases).Count | Should Be 2
      (Get-Content -LiteralPath (Join-Path $requestCaptureRoot 'request-3.json') -Raw -Encoding UTF8) | Should Match 'Case id: unknown-case'
      (Get-Content -LiteralPath (Join-Path $requestCaptureRoot 'request-3.json') -Raw -Encoding UTF8) | Should Not Match 'Case id: known-case'
      @(Get-ChildItem -LiteralPath $requestCaptureRoot -Filter 'request-*.json').Count | Should Be 3
      Wait-Job -Job $server.job -Timeout 3 | Out-Null
      $server.job.State | Should Be 'Completed'
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_ANSWER_KEY -ErrorAction SilentlyContinue
      Stop-Phase6AnswerSseServer $server
    }
  }

  It 'fails closed instead of replaying an indeterminate Phase 6 batch' {
    $runRoot = Join-Path $TestDrive 'checkpoint-indeterminate'
    $input = New-Phase6CheckpointTestInput $runRoot
    $outputPath = Join-Path $runRoot 'answers.json'
    $responseTexts = @(
      '{"cases":[{"id":"transport-probe","answerText":"probe-ok"}]}',
      '{"cases":[{"id":"known-case","answerText":"known-42"}]}'
    ) | ConvertTo-Json -Compress
    $server = Start-Phase6AnswerSseServer -RequestCount 2 -ResponseTextsJson $responseTexts
    $env:SUPER_BRAIN_TEST_ANSWER_KEY = 'test-answer-key'
    try {
      $probe = Invoke-Phase6Generator @('-Action','Probe','-Apply','-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-Json')
      $probe.exitCode | Should Be 0
      $partial = Invoke-Phase6Generator @('-Action','Generate','-Apply','-AnswerInputPath',$input.inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-BatchSize','1','-MaxNewBatches','1','-Json')
      $partial.exitCode | Should Be 0
      $checkpointPath = [string]$partial.value.checkpointPath
      $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $checkpoint.batches[1].status = 'in_progress'
      $checkpoint.batches[1].attemptCount = 1
      [IO.File]::WriteAllText($checkpointPath,($checkpoint | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))

      $resume = Invoke-Phase6Generator @('-Action','Generate','-Apply','-Resume','-AnswerInputPath',$input.inputPath,'-OutputPath',$outputPath,'-ResponsesUrl',$server.url,'-ApiKeyEnv','SUPER_BRAIN_TEST_ANSWER_KEY','-TimeoutSeconds','30','-BatchSize','1','-Json')
      $resume.exitCode | Should Be 1
      $resume.value.code | Should Be 'PHASE6_CHECKPOINT_INDETERMINATE'
      Test-Path -LiteralPath $outputPath | Should Be $false
      Wait-Job -Job $server.job -Timeout 3 | Out-Null
      $server.job.State | Should Be 'Completed'
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_ANSWER_KEY -ErrorAction SilentlyContinue
      Stop-Phase6AnswerSseServer $server
    }
  }

  It 'exports and imports a blinded host-native batch without expected data' {
    $runRoot = Join-Path $TestDrive 'native-host-batch'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $sourcePath = Join-Path $runRoot 'source.json'
    $sealedPath = Join-Path $runRoot 'sealed.json'
    $inputPath = Join-Path $runRoot 'private-input.json'
    $batchPath = Join-Path $runRoot 'native-batch.json'
    $responsePath = Join-Path $runRoot 'native-response.json'
    $artifactPath = Join-Path $runRoot 'native-answers.json'
    $reportPath = Join-Path $runRoot 'native-report.json'
    $source = [pscustomobject]@{
      schema = 'super-brain.memory-e2e-source.v1'
      setId = 'phase6-native-host-test'
      cases = @(
        [pscustomobject]@{
          id = 'alpha-case'
          familyId = 'alpha-family'
          category = 'information_extraction'
          records = @([pscustomobject]@{ id='alpha-evidence'; text='[CURRENT][VERIFIED] Native alpha value is aurora.'; layer='project' })
          query = 'What is the native alpha value?'
          expected = [pscustomobject]@{ evidenceIds=@('alpha-evidence'); answer=[pscustomobject]@{ mode='answer'; requiredPhrases=@('aurora') } }
        },
        [pscustomobject]@{
          id = 'unknown-case'
          familyId = 'unknown-native-family'
          category = 'unsupported_unknown'
          records = @([pscustomobject]@{ id='unknown-evidence'; text='[CURRENT][VERIFIED] No native beta value is available.'; layer='project' })
          query = 'What unavailable native beta value should be returned?'
          expected = [pscustomobject]@{ evidenceIds=@(); answer=[pscustomobject]@{ mode='abstain'; requiredPhrases=@() } }
        }
      )
    }
    Write-Phase6GeneratorJson $sourcePath $source
    (Invoke-Phase6Wrapper @('-Action','Seal','-SourcePath',$sourcePath,'-OutputPath',$sealedPath,'-Json')).exitCode | Should Be 0
    (Invoke-Phase6Wrapper @('-Action','PrepareAnswerInput','-SealedPath',$sealedPath,'-OutputPath',$inputPath,'-Json')).exitCode | Should Be 0

    $export = Invoke-Phase6Generator @('-Action','ExportNative','-Apply','-AnswerInputPath',$inputPath,'-OutputPath',$batchPath,'-Json')
    $export.exitCode | Should Be 0
    $export.value.status | Should Be 'native_batch_exported_private'
    $batch = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $batch.schema | Should Be 'super-brain.phase6-native-answer-batch.v1'
    $batch.privacy.expectedAnswerDataAvailable | Should Be $false
    $batch.privacy.rawExpectedDataStored | Should Be $false
    $batch.privacy.rawModelTranscriptStored | Should Be $false
    foreach ($case in @($batch.cases)) {
      ($case.PSObject.Properties.Name -contains 'caseHash') | Should Be $false
      ($case.PSObject.Properties.Name -contains 'expected') | Should Be $false
      ($case.PSObject.Properties.Name -contains 'records') | Should Be $false
    }

    $response = [pscustomobject]@{
      schema = 'super-brain.host-native-agent-response.v1'
      batchId = $batch.batchId
      batchHash = $batch.batchHash
      cases = @(
        [pscustomobject]@{ id='alpha-case'; answerText='aurora' },
        [pscustomobject]@{ id='unknown-case'; answerText='' }
      )
    }
    Write-Phase6GeneratorJson $responsePath $response
    $import = Invoke-Phase6Generator @('-Action','ImportNative','-Apply','-AnswerInputPath',$inputPath,'-NativeBatchPath',$batchPath,'-NativeResponsePath',$responsePath,'-NativeAgentId','native-agent-01','-NativeDispatchId','native-dispatch-01','-OutputPath',$artifactPath,'-Json')
    $import.exitCode | Should Be 0
    $import.value.status | Should Be 'native_agent_artifact_imported_private'
    $artifact = Get-Content -LiteralPath $artifactPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $artifact.provenance.kind | Should Be 'host_native_agent_blinded_input'
    $artifact.provenance.hostedNativeAgent | Should Be $true
    $artifact.provenance.hostAgentId | Should Be 'native-agent-01'
    $artifact.provenance.hostDispatchReceiptSha256 | Should Match '^[0-9a-f]{64}$'
    $receiptHash = (Get-FileHash -LiteralPath $import.value.receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $artifact.provenance.hostDispatchReceiptSha256 | Should Be $receiptHash
    $alpha = @($artifact.cases | Where-Object { $_.id -eq 'alpha-case' })[0]
    $alpha.claims[0].evidenceIds[0] | Should Be 'alpha-evidence'

    $run = Invoke-Phase6Wrapper @('-Action','Run','-SealedPath',$sealedPath,'-AnswerInputPath',$inputPath,'-AnswerArtifactPath',$artifactPath,'-OutputPath',$reportPath,'-Json')
    $run.exitCode | Should Be 0
    $run.value.status | Should Be 'internal_acceptance_only'
    $run.value.answerEvaluation.provenanceKind | Should Be 'host_native_agent_blinded_input'
    $run.value.overall.groundingRate | Should Be 1
  }
}
