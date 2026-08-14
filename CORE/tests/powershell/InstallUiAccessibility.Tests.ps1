Describe 'Super Memory Brain Control Center accessibility contract' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $root 'scripts\common.ps1')
    $entryRoot = Get-SuperBrainRuntimeWorkspaceRoot $root
    $script:regression = Get-Content -LiteralPath (Join-Path $root 'scripts\install-ui-regression.ps1') -Raw -Encoding UTF8
  }

  It 'tracks rendered Control Center assets in the install regression freshness binding' {
    foreach ($path in @('runtime\brain_ui_server.py','ui\src\main.tsx','ui\src\styles.css','ui\dist\index.html','ui\dist\assets\app.js','ui\dist\assets\app.css')) {
      $regression.Contains($path) | Should Be $true
    }
  }

  It 'tracks the direct-root user entry layer and keeps its launchers root-relative' {
    foreach ($path in @('START_HERE.md','install-ui.bat','open-ui.bat','01-INSTALL-AND-MAINTAIN.vbs','02-DAILY-CONTROL-CENTER.vbs')) {
      $script:regression.Contains($path) | Should Be $true
    }
    (Get-Content -LiteralPath (Join-Path $entryRoot '01-INSTALL-AND-MAINTAIN.vbs') -Raw -Encoding UTF8).Contains('CORE\scripts\install-ui.vbs') | Should Be $true
    (Get-Content -LiteralPath (Join-Path $entryRoot '02-DAILY-CONTROL-CENTER.vbs') -Raw -Encoding UTF8).Contains('CORE\scripts\brain-ui.vbs') | Should Be $true
  }

  It 'keeps keyboard, responsive, motion, and loopback privacy checks in the maintained UI gate' {
    foreach ($marker in @('Test-ControlCenterAccessibilityContract','semantic_navigation','live_updates','keyboard_search','starmap_label','starmap_deselect','starmap_node_title','starmap_single_title','starmap_label_bounds','starmap_selection_focus','starmap_full_height','memory_category_grouping','timeline_explicit_actions','managed_recycle_bin','trash_delete_acknowledgement','console_profile_navigation_removed','visible_focus','motion_reduction','mobile_layout','long_text_wrap','loopback_capability','control_center_accessibility_contract')) {
      $regression.Contains($marker) | Should Be $true
    }
  }

  It 'keeps the star map selection exit, labels, and desktop-height contracts explicit' {
    $main = Get-Content -LiteralPath (Join-Path $root 'ui\src\main.tsx') -Raw -Encoding UTF8
    $styles = Get-Content -LiteralPath (Join-Path $root 'ui\src\styles.css') -Raw -Encoding UTF8
    $main.Contains('clearStarmapSelection') | Should Be $true
    $main.Contains('createStarmapNodeLabel') | Should Be $true
    $main.Contains('node.kind === "task" || graph.nodes.length === 1') | Should Be $false
    $main.Contains('className: "starmap-single-node"') | Should Be $false
    $main.Contains('starmapNodeLabel(singleNode)') | Should Be $false
    $main.Contains('selectableNodes.length > 0') | Should Be $true
    $main.Contains('const labelX = Math.max') | Should Be $true
    $main.Contains('onSelectRef.current(null)') | Should Be $true
    $main.Contains('event.key === "Escape"') | Should Be $true
    $main.Contains('const focusTarget = new THREE.Vector3') | Should Be $true
    $main.Contains('cameraState.target.lerp(focusTarget') | Should Be $true
    $styles.Contains('height: 100dvh') | Should Be $true
  }

  It 'keeps the five user-facing memory groups and governed list/recycle paths explicit' {
    $main = Get-Content -LiteralPath (Join-Path $root 'ui\src\main.tsx') -Raw -Encoding UTF8
    $server = Get-Content -LiteralPath (Join-Path $root 'runtime\brain_ui_server.py') -Raw -Encoding UTF8
    $main.Contains('MEMORY_CATEGORIES') | Should Be $true
    $main.Contains('decision-procedure') | Should Be $true
    $main.Contains('function ManagedRecycleBin') | Should Be $true
    $main.Contains('openTrash') | Should Be $true
    $main.Contains('onClick: () => props.onOpen(item)') | Should Be $true
    $main.Contains('event.stopPropagation(); props.onTrash(item);') | Should Be $true
    $main.Contains('deleteAcknowledged: true') | Should Be $true
    $server.Contains('cardRef') | Should Be $true
    $server.Contains('BRAIN_UI_TRASH_DELETE_ACKNOWLEDGEMENT_REQUIRED') | Should Be $true
  }

  It 'uses an external temporary import root before validating the migration dry-run' {
    $regression.Contains("New-Item -ItemType Directory -Force -Path `$Workspace,(Join-Path `$MemoryBase 'shared') | Out-Null") | Should Be $true
    $regression.Contains("Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-install-ui-import-'") | Should Be $true
    $regression.Contains("New-Item -ItemType Directory -Force -Path `$importRoot | Out-Null") | Should Be $true
    $regression.Contains("migrate-memory-layout.ps1' -ScriptParams @{ ImportRoot = `$importRoot; Mode = 'Merge' }") | Should Be $true
    $regression.Contains('Remove-Item -LiteralPath $importRoot -Recurse -Force -ErrorAction SilentlyContinue') | Should Be $true
    $regression.Contains("MIGRATION action=plan") | Should Be $true
    $regression.Contains("MIGRATION_GUARD") | Should Be $true
  }
}
