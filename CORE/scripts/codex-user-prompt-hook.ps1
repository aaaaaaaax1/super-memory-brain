[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$TestPrompt = '',
  [string]$TestWorkspace = '',
  [string]$TestSessionId = '',
  [string]$TestAgentId = '',
  [string]$TestAgentType = ''
)

# Retired P7/UserPromptSubmit compatibility shim.
# H7 brain_turn is the only Super Brain lifecycle authority. A stale Desktop
# Host may invoke this path, but it must complete successfully without reading
# prompt input or mutating state.
exit 0
