param(
  [Parameter(Mandatory=$true)][string]$Subject,
  [Parameter(Mandatory=$true)][string]$Relation,
  [Parameter(Mandatory=$true)][string]$Object,
  [string]$Evidence = '',
  [string]$Tags = '[VERIFIED]'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Graph = Join-Path $Root 'memory\graph.jsonl'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Graph) | Out-Null

$record = [ordered]@{
  time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  subject = $Subject
  relation = $Relation
  object = $Object
  evidence = $Evidence
  tags = $Tags
}
($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Graph -Encoding UTF8
Write-Host "GRAPH_ADD_OK $Graph"
