$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runnerPath = Join-Path $root 'scripts\objective-benchmark-runner.ps1'

function Write-BlindRunnerJson([string]$Path,$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
}

function Invoke-BlindRunner([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runnerPath @Arguments 2>$null)
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=(($raw -join "`n") | ConvertFrom-Json) }
}

function Get-TestTextSha256([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Get-TestCaseSetHash($Cases) {
  $parts = @($Cases | Sort-Object id | ForEach-Object {
    $shapeHash = Get-TestTextSha256 (([string]$_.id) + "`n" + ([string]$_.prompt) + "`n" + ([string]$_.reference) + "`n" + ([string]$_.rubric))
    ([string]$_.id) + "`n" + $shapeHash
  })
  return Get-TestTextSha256 ($parts -join "`n")
}

function Get-TestJudgeModelEvidenceHash($Decisions) {
  $parts = @($Decisions | Sort-Object id | ForEach-Object { ([string]$_.id) + "`n" + ([string]$_.responseModel) })
  return Get-TestTextSha256 ($parts -join "`n")
}

function New-AnswerArtifact([bool]$Enabled,[string]$Suffix) {
  $manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $reportedModel = 'host-model-test'
  $cases = @(
    [pscustomobject]@{ id='case-1'; prompt='Task one'; reference='Reference one'; rubric='Be correct'; answer=if($Enabled){'treatment answer one'}else{'baseline answer one'}; responseModel=$reportedModel },
    [pscustomobject]@{ id='case-2'; prompt='Task two'; reference='Reference two'; rubric='Be correct'; answer=if($Enabled){'treatment answer two'}else{'baseline answer two'}; responseModel=$reportedModel }
  )
  return [pscustomobject]@{
    schema = 'super-brain.objective-answer-artifact.v1'
    caseSetHash = Get-TestCaseSetHash $cases
    generator = [pscustomobject]@{
      runId = "run-$Suffix"
      executionId = "execution-$Suffix"
      modelId = 'host-model-test'
      modelVersion = $reportedModel
      requestedModelId = 'host-model-test'
      reportedModelId = $reportedModel
      benchmarkVariant = 's_cleaned'
      responseCount = 2
      responseModelEvidenceSha256 = Get-TestTextSha256 ("case-1`n$reportedModel`ncase-2`n$reportedModel")
      toolchainHash = 'toolchain-test'
      budgetHash = 'budget-test'
      environmentHash = 'environment-test'
      promptTemplateHash = 'prompt-template-test'
      packageVersion = [string]$manifest.version
      subjectHash = 'subject-test'
      packageManifestSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
      brainCoreSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'runtime\brain_core.py') -Algorithm SHA256).Hash.ToLowerInvariant()
      memoryPolicySha256 = (Get-FileHash -LiteralPath (Join-Path $root 'memory-policy.json') -Algorithm SHA256).Hash.ToLowerInvariant()
      corpusHash = 'corpus-test'
      harnessHash = 'harness-test'
      selectionSha256 = 'selection-test'
      configFingerprint = 'config-test'
      independentExecution = $true
      superMemoryBrainEnabled = $Enabled
    }
    cases = $cases
  }
}

function New-JudgeResult([string]$JudgeInputPath,[string]$InputHash) {
  $input = Get-Content -LiteralPath $JudgeInputPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $judgeModel = [string]$input.judge.modelId
  $decisions = @($input.cases | ForEach-Object { [pscustomobject]@{ id=[string]$_.id; candidateA=[pscustomobject]@{passed=$true}; candidateB=[pscustomobject]@{passed=$false}; responseSha256='response-test'; responseModel=$judgeModel } })
  return [pscustomobject]@{
    schema = 'super-brain.objective-blind-judge-result.v1'
    status = 'completed'
    createdAt = (Get-Date).ToString('o')
    judgeInputSha256 = $InputHash
    judge = [pscustomobject]@{ modelId=[string]$input.judge.modelId; reportedModelId=[string]$input.judge.modelId; modelIdentityVerified=$true; reasoningEffort=[string]$input.judge.reasoningEffort; judgeRunId='judge-test'; independentExecution=$true; endpointSha256='endpoint-test'; responseCount=$decisions.Count; responseModelEvidenceSha256=(Get-TestJudgeModelEvidenceHash $decisions) }
    decisions = $decisions
    rawJudgeResponseStored = $false
  }
}

function Start-TestJudgeSseServer([string]$Model='gpt-5.6-luna',[string]$Text='OK') {
  $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  $portProbe.Start()
  $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
  $portProbe.Stop()
  $prefix = "http://127.0.0.1:$port/"
  $readyPath = Join-Path $TestDrive "judge-sse-$port.ready"
  $job = Start-Job -ScriptBlock {
    param($Prefix,$ReadyPath,$Model,$Text)
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    try {
      $listener.Start()
      [IO.File]::WriteAllText($ReadyPath,'ready',[Text.UTF8Encoding]::new($false))
      $context = $listener.GetContext()
      $payload = [pscustomobject]@{
        type = 'response.completed'
        response = [pscustomobject]@{
          id = 'response-test'
          object = 'response'
          model = $Model
          status = 'completed'
          output = @([pscustomobject]@{
            type = 'message'
            content = @([pscustomobject]@{ type='output_text'; text=$Text })
          })
        }
      } | ConvertTo-Json -Depth 10 -Compress
      $body = "event: response.completed`ndata: $payload`n`n"
      $bytes = [Text.Encoding]::UTF8.GetBytes($body)
      $context.Response.StatusCode = 200
      $context.Response.ContentType = 'text/event-stream'
      $context.Response.ContentLength64 = $bytes.Length
      $context.Response.OutputStream.Write($bytes,0,$bytes.Length)
      $context.Response.OutputStream.Close()
    } finally {
      if ($listener.IsListening) { $listener.Stop() }
      $listener.Close()
    }
  } -ArgumentList $prefix,$readyPath,$Model,$Text
  $deadline = (Get-Date).AddSeconds(10)
  while (-not (Test-Path -LiteralPath $readyPath) -and (Get-Date) -lt $deadline -and $job.State -notin @('Failed','Completed','Stopped')) {
    Start-Sleep -Milliseconds 50
  }
  if (-not (Test-Path -LiteralPath $readyPath)) {
    $detail = @($job | Receive-Job -ErrorAction SilentlyContinue) -join "`n"
    $job | Stop-Job -ErrorAction SilentlyContinue
    $job | Remove-Job -Force -ErrorAction SilentlyContinue
    throw "Test SSE judge server failed to start: $detail"
  }
  return [pscustomobject]@{ url=($prefix + 'responses'); job=$job; readyPath=$readyPath }
}

function Stop-TestJudgeSseServer($Server) {
  if (-not $Server) { return }
  $Server.job | Wait-Job -Timeout 10 | Out-Null
  if ($Server.job.State -notin @('Completed','Failed','Stopped')) { $Server.job | Stop-Job -ErrorAction SilentlyContinue }
  $Server.job | Receive-Job -ErrorAction SilentlyContinue | Out-Null
  $Server.job | Remove-Job -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Server.readyPath -Force -ErrorAction SilentlyContinue
}

Describe 'Objective blind runner contract' {
  It 'prepares opaque randomized A/B judge input without condition labels' {
    $runRoot = Join-Path $TestDrive 'prepare'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $statePath = Join-Path $runRoot 'state.json'
    $inputPath = Join-Path $runRoot 'judge-input.json'
    Write-BlindRunnerJson $baselinePath (New-AnswerArtifact $false 'baseline')
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')

    $result = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',$statePath,'-JudgeInputPath',$inputPath,'-JudgeModel','gpt-5.6-luna','-JudgeReasoningEffort','max','-Json')
    $result.exitCode | Should Be 0
    $result.value.status | Should Be 'awaiting_judge'
    $result.value.caseCount | Should Be 2
    $blind = Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    ($blind.PSObject.Properties.Name -match '(?i)baseline|treatment').Count | Should Be 0
    foreach ($case in @($blind.cases)) {
      ($case.PSObject.Properties.Name -match '(?i)baseline|treatment|condition').Count | Should Be 0
    }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($state.pairings).Count | Should Be 2
    $state.rawAnswersStored | Should Be $false
  }

  It 'finalizes judged artifacts without retaining raw answers or judge replies' {
    $runRoot = Join-Path $TestDrive 'finalize'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $statePath = Join-Path $runRoot 'state.json'
    $inputPath = Join-Path $runRoot 'judge-input.json'
    $judgeResultPath = Join-Path $runRoot 'judge-result.json'
    $reportPath = Join-Path $runRoot 'report.json'
    Write-BlindRunnerJson $baselinePath (New-AnswerArtifact $false 'baseline')
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')
    $prepared = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',$statePath,'-JudgeInputPath',$inputPath,'-Json')
    $prepared.exitCode | Should Be 0
    Write-BlindRunnerJson $judgeResultPath (New-JudgeResult $inputPath ([string]$prepared.value.judgeInputSha256))

    $result = Invoke-BlindRunner @('-Action','Finalize','-StatePath',$statePath,'-ExpectedStateSha256',([string]$prepared.value.stateSha256),'-JudgeResultPath',$judgeResultPath,'-OutputPath',$reportPath,'-Json')
    $result.exitCode | Should Be 0
    $result.value.status | Should Be 'diagnostic_non_publishable'
    $result.value.metrics.total | Should Be 2
    ($result.value.metrics.baselinePassed + $result.value.metrics.treatmentPassed) | Should Be 2
    $reportText = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
    $reportText | Should Not Match 'baseline answer'
    $reportText | Should Not Match 'treatment answer'
    $result.value.provenance.blindedJudging | Should Be $true
    $result.value.provenance.rawJudgeResponseStored | Should Be $false
  }

  It 'rejects a tampered judge input before unblinding' {
    $runRoot = Join-Path $TestDrive 'tamper'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $statePath = Join-Path $runRoot 'state.json'
    $inputPath = Join-Path $runRoot 'judge-input.json'
    $judgeResultPath = Join-Path $runRoot 'judge-result.json'
    $reportPath = Join-Path $runRoot 'report.json'
    Write-BlindRunnerJson $baselinePath (New-AnswerArtifact $false 'baseline')
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')
    $prepared = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',$statePath,'-JudgeInputPath',$inputPath,'-Json')
    $prepared.exitCode | Should Be 0
    Write-BlindRunnerJson $judgeResultPath (New-JudgeResult $inputPath ([string]$prepared.value.judgeInputSha256))
    $input = Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $input.cases[0].candidateA = 'tampered candidate'
    Write-BlindRunnerJson $inputPath $input

    $result = Invoke-BlindRunner @('-Action','Finalize','-StatePath',$statePath,'-ExpectedStateSha256',([string]$prepared.value.stateSha256),'-JudgeResultPath',$judgeResultPath,'-OutputPath',$reportPath,'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'JUDGE_INPUT_TAMPERED'
  }

  It 'rejects answer artifacts whose per-case actual model drifts' {
    $runRoot = Join-Path $TestDrive 'model-drift'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $baseline = New-AnswerArtifact $false 'baseline'
    $baseline.cases[0].responseModel = 'unexpected-model'
    Write-BlindRunnerJson $baselinePath $baseline
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')

    $result = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',(Join-Path $runRoot 'state.json'),'-JudgeInputPath',(Join-Path $runRoot 'judge-input.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'ANSWER_RESPONSE_MODEL_MISMATCH'
  }

  It 'rejects answer artifacts whose declared reported model differs from the requested model' {
    $runRoot = Join-Path $TestDrive 'declared-model-drift'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $baseline = New-AnswerArtifact $false 'baseline'
    $baseline.generator.modelVersion = 'unexpected-model'
    $baseline.generator.reportedModelId = 'unexpected-model'
    foreach ($case in @($baseline.cases)) { $case.responseModel = 'unexpected-model' }
    $baseline.generator.responseModelEvidenceSha256 = Get-TestTextSha256 "case-1`nunexpected-model`ncase-2`nunexpected-model"
    Write-BlindRunnerJson $baselinePath $baseline
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')

    $result = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',(Join-Path $runRoot 'state.json'),'-JudgeInputPath',(Join-Path $runRoot 'judge-input.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'ANSWER_MODEL_IDENTITY_INVALID'
  }

  It 'rejects paired artifacts with different benchmark variants' {
    $runRoot = Join-Path $TestDrive 'benchmark-variant-drift'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $baseline = New-AnswerArtifact $false 'baseline'
    $baseline.generator.benchmarkVariant = 'oracle'
    Write-BlindRunnerJson $baselinePath $baseline
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')

    $result = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',(Join-Path $runRoot 'state.json'),'-JudgeInputPath',(Join-Path $runRoot 'judge-input.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'GENERATOR_CONDITIONS_MISMATCH'
  }

  It 'rejects a judge result whose actual model is unverified' {
    $runRoot = Join-Path $TestDrive 'judge-model-drift'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $statePath = Join-Path $runRoot 'state.json'
    $inputPath = Join-Path $runRoot 'judge-input.json'
    $judgeResultPath = Join-Path $runRoot 'judge-result.json'
    Write-BlindRunnerJson $baselinePath (New-AnswerArtifact $false 'baseline')
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')
    $prepared = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',$statePath,'-JudgeInputPath',$inputPath,'-Json')
    $judgeResult = New-JudgeResult $inputPath ([string]$prepared.value.judgeInputSha256)
    $judgeResult.judge.reportedModelId = 'unexpected-judge'
    Write-BlindRunnerJson $judgeResultPath $judgeResult

    $result = Invoke-BlindRunner @('-Action','Finalize','-StatePath',$statePath,'-ExpectedStateSha256',([string]$prepared.value.stateSha256),'-JudgeResultPath',$judgeResultPath,'-OutputPath',(Join-Path $runRoot 'report.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'JUDGE_REPORTED_MODEL_MISMATCH'
  }

  It 'rejects a stale self-reported case-set hash' {
    $runRoot = Join-Path $TestDrive 'case-set-hash'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $baseline = New-AnswerArtifact $false 'baseline'
    $baseline.caseSetHash = 'stale-case-set-hash'
    Write-BlindRunnerJson $baselinePath $baseline
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')

    $result = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',(Join-Path $runRoot 'state.json'),'-JudgeInputPath',(Join-Path $runRoot 'judge-input.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'ANSWER_CASE_SET_HASH_MISMATCH'
  }

  It 'rejects source answer mutation after blind preparation' {
    $runRoot = Join-Path $TestDrive 'source-mutation'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $statePath = Join-Path $runRoot 'state.json'
    $inputPath = Join-Path $runRoot 'judge-input.json'
    $judgeResultPath = Join-Path $runRoot 'judge-result.json'
    Write-BlindRunnerJson $baselinePath (New-AnswerArtifact $false 'baseline')
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')
    $prepared = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',$statePath,'-JudgeInputPath',$inputPath,'-Json')
    Write-BlindRunnerJson $judgeResultPath (New-JudgeResult $inputPath ([string]$prepared.value.judgeInputSha256))
    $baseline = Get-Content -LiteralPath $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $baseline.generator.runId = 'mutated-run'
    Write-BlindRunnerJson $baselinePath $baseline

    $result = Invoke-BlindRunner @('-Action','Finalize','-StatePath',$statePath,'-ExpectedStateSha256',([string]$prepared.value.stateSha256),'-JudgeResultPath',$judgeResultPath,'-OutputPath',(Join-Path $runRoot 'report.json'),'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'ANSWER_ARTIFACT_TAMPERED'
  }

  It 'reuses a completed valid judge checkpoint without endpoint configuration' {
    $runRoot = Join-Path $TestDrive 'completed-judge-resume'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $statePath = Join-Path $runRoot 'state.json'
    $inputPath = Join-Path $runRoot 'judge-input.json'
    $judgeResultPath = Join-Path $runRoot 'judge-result.json'
    Write-BlindRunnerJson $baselinePath (New-AnswerArtifact $false 'baseline')
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')
    $prepared = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',$statePath,'-JudgeInputPath',$inputPath,'-Json')
    Write-BlindRunnerJson $judgeResultPath (New-JudgeResult $inputPath ([string]$prepared.value.judgeInputSha256))

    $result = Invoke-BlindRunner @('-Action','Judge','-Apply','-JudgeInputPath',$inputPath,'-JudgeResultPath',$judgeResultPath,'-Json')
    $result.exitCode | Should Be 0
    $result.value.status | Should Be 'judged'
    $result.value.resumedCount | Should Be 2
    $result.value.newDecisionCount | Should Be 0
  }

  It 'rejects a completed judge checkpoint without endpoint evidence' {
    $runRoot = Join-Path $TestDrive 'completed-judge-missing-endpoint'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $baselinePath = Join-Path $runRoot 'baseline.json'
    $treatmentPath = Join-Path $runRoot 'treatment.json'
    $statePath = Join-Path $runRoot 'state.json'
    $inputPath = Join-Path $runRoot 'judge-input.json'
    $judgeResultPath = Join-Path $runRoot 'judge-result.json'
    Write-BlindRunnerJson $baselinePath (New-AnswerArtifact $false 'baseline')
    Write-BlindRunnerJson $treatmentPath (New-AnswerArtifact $true 'treatment')
    $prepared = Invoke-BlindRunner @('-Action','Prepare','-BaselinePath',$baselinePath,'-TreatmentPath',$treatmentPath,'-StatePath',$statePath,'-JudgeInputPath',$inputPath,'-Json')
    $judgeResult = New-JudgeResult $inputPath ([string]$prepared.value.judgeInputSha256)
    $judgeResult.judge.PSObject.Properties.Remove('endpointSha256')
    Write-BlindRunnerJson $judgeResultPath $judgeResult

    $result = Invoke-BlindRunner @('-Action','Judge','-Apply','-JudgeInputPath',$inputPath,'-JudgeResultPath',$judgeResultPath,'-Json')
    $result.exitCode | Should Be 1
    $result.value.code | Should Be 'JUDGE_CHECKPOINT_ENDPOINT_MISSING'
  }

  It 'writes exact judge identity into a streamed partial checkpoint' {
    $runRoot = Join-Path $TestDrive 'streamed-judge-identity'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $inputPath = Join-Path $runRoot 'judge-input.json'
    $judgeResultPath = Join-Path $runRoot 'judge-result.json'
    $decisionText = '{"candidateA":{"passed":true},"candidateB":{"passed":false}}'
    $server = Start-TestJudgeSseServer 'gpt-5.6-luna' $decisionText
    $input = [pscustomobject]@{
      schema = 'super-brain.objective-blind-judge-input.v1'
      judgeRequestId = 'judge-input-test'
      createdAt = (Get-Date).ToString('o')
      caseSetHash = 'case-set-test'
      caseCount = 1
      judge = [pscustomobject]@{ modelId='gpt-5.6-luna'; reasoningEffort='max'; independentExecution=$true }
      rubric = 'Return the requested JSON decision.'
      rubricSha256 = 'rubric-test'
      cases = @([pscustomobject]@{
        id = 'case-1'
        prompt = 'Task one'
        reference = 'Reference one'
        rubric = 'Be correct'
        candidateA = 'Answer A'
        candidateB = 'Answer B'
      })
    }
    Write-BlindRunnerJson $inputPath $input
    $env:SUPER_BRAIN_TEST_JUDGE_KEY = 'test-key'
    try {
      $result = Invoke-BlindRunner @('-Action','Judge','-Apply','-JudgeInputPath',$inputPath,'-JudgeResultPath',$judgeResultPath,'-JudgeResponsesUrl',$server.url,'-JudgeApiKeyEnv','SUPER_BRAIN_TEST_JUDGE_KEY','-TimeoutSeconds','30','-Json')
      $result.exitCode | Should Be 0
      $result.value.status | Should Be 'judged'
      $checkpoint = Get-Content -LiteralPath $judgeResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $checkpoint.judge.modelId | Should Be 'gpt-5.6-luna'
      $checkpoint.judge.reportedModelId | Should Be 'gpt-5.6-luna'
      $checkpoint.judge.reasoningEffort | Should Be 'max'
      $checkpoint.judge.responseCount | Should Be 1
      @($checkpoint.decisions).Count | Should Be 1
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_JUDGE_KEY -ErrorAction SilentlyContinue
      Stop-TestJudgeSseServer $server
    }
  }

  It 'repairs only a validated legacy blank-identity partial checkpoint' {
    $runRoot = Join-Path $TestDrive 'legacy-blank-identity'
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $inputPath = Join-Path $runRoot 'judge-input.json'
    $judgeResultPath = Join-Path $runRoot 'judge-result.json'
    $input = [pscustomobject]@{
      schema = 'super-brain.objective-blind-judge-input.v1'
      judgeRequestId = 'judge-input-legacy-test'
      createdAt = (Get-Date).ToString('o')
      caseSetHash = 'case-set-test'
      caseCount = 1
      judge = [pscustomobject]@{ modelId='gpt-5.6-luna'; reasoningEffort='max'; independentExecution=$true }
      rubric = 'Return the requested JSON decision.'
      rubricSha256 = 'rubric-test'
      cases = @([pscustomobject]@{
        id = 'case-1'
        prompt = 'Task one'
        reference = 'Reference one'
        rubric = 'Be correct'
        candidateA = 'Answer A'
        candidateB = 'Answer B'
      })
    }
    Write-BlindRunnerJson $inputPath $input
    $inputHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $decision = [pscustomobject]@{
      id = 'case-1'
      candidateA = [pscustomobject]@{ passed=$true }
      candidateB = [pscustomobject]@{ passed=$false }
      responseSha256 = 'response-test'
      responseModel = 'gpt-5.6-luna'
    }
    $checkpoint = [pscustomobject]@{
      schema = 'super-brain.objective-blind-judge-result.v1'
      status = 'partial'
      createdAt = (Get-Date).ToString('o')
      judgeInputSha256 = $inputHash
      judge = [pscustomobject]@{
        modelId = ''
        reportedModelId = ''
        modelIdentityVerified = $true
        reasoningEffort = ''
        judgeRunId = 'judge-legacy-test'
        independentExecution = $true
        endpointSha256 = Get-TestTextSha256 'http://127.0.0.1:29999'
        responseCount = 1
        responseModelEvidenceSha256 = Get-TestJudgeModelEvidenceHash @($decision)
      }
      decisions = @($decision)
      rawJudgeResponseStored = $false
    }
    Write-BlindRunnerJson $judgeResultPath $checkpoint
    $env:SUPER_BRAIN_TEST_JUDGE_KEY = 'test-key'
    try {
      $result = Invoke-BlindRunner @('-Action','Judge','-Apply','-JudgeInputPath',$inputPath,'-JudgeResultPath',$judgeResultPath,'-JudgeResponsesUrl','http://127.0.0.1:29999/responses','-JudgeApiKeyEnv','SUPER_BRAIN_TEST_JUDGE_KEY','-TimeoutSeconds','30','-Json')
      $result.exitCode | Should Be 0
      $result.value.resumedCount | Should Be 1
      $result.value.newDecisionCount | Should Be 0
      $repaired = Get-Content -LiteralPath $judgeResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $repaired.status | Should Be 'completed'
      $repaired.judge.modelId | Should Be 'gpt-5.6-luna'
      $repaired.judge.reportedModelId | Should Be 'gpt-5.6-luna'
      $repaired.judge.reasoningEffort | Should Be 'max'
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_JUDGE_KEY -ErrorAction SilentlyContinue
    }
  }

  It 'parses a Responses SSE probe through the completed response object' {
    $server = Start-TestJudgeSseServer
    $env:SUPER_BRAIN_TEST_JUDGE_KEY = 'test-key'
    try {
      $result = Invoke-BlindRunner @('-Action','Probe','-Apply','-JudgeResponsesUrl',$server.url,'-JudgeApiKeyEnv','SUPER_BRAIN_TEST_JUDGE_KEY','-JudgeModel','gpt-5.6-luna','-JudgeReasoningEffort','max','-TimeoutSeconds','30','-Json')
      $result.exitCode | Should Be 0
      $result.value.status | Should Be 'reachable'
      $result.value.reportedModelId | Should Be 'gpt-5.6-luna'
      $result.value.modelIdentityVerified | Should Be $true
    } finally {
      Remove-Item Env:\SUPER_BRAIN_TEST_JUDGE_KEY -ErrorAction SilentlyContinue
      Stop-TestJudgeSseServer $server
    }
  }
}
