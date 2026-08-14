Option Explicit

' CONTROL_CENTER_LAUNCHER
' LEGACY_BRAIN_UI_COMPATIBILITY: this launcher does not install Super Brain.
' The normal entry point starts the local loopback Control Center. The legacy
' install UI remains a recovery/install surface only when this package predates
' the new control center assets.

Dim fso, shell, scriptDir, rootDir, installUiVbs, installUiPs1, controlCenterPs1, controlCenterServer, controlCenterIndex, exitCode
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
rootDir = fso.GetParentFolderName(scriptDir)
installUiVbs = rootDir & "\scripts\install-ui.vbs"
installUiPs1 = rootDir & "\scripts\install-ui.ps1"
controlCenterPs1 = rootDir & "\scripts\open-control-center.ps1"
controlCenterServer = rootDir & "\runtime\brain_ui_server.py"
controlCenterIndex = rootDir & "\ui\dist\index.html"

If fso.FileExists(controlCenterPs1) And fso.FileExists(controlCenterServer) And fso.FileExists(controlCenterIndex) Then
  exitCode = shell.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File " & Q(controlCenterPs1), 0, True)
  If exitCode = 0 Then WScript.Quit 0
  MsgBox "The local Super Brain Control Center could not start. It did not fall back to the legacy installer UI because that would hide a runtime failure.", _
         vbCritical, "Super Brain Control Center"
  WScript.Quit exitCode
End If

If Not fso.FileExists(installUiVbs) Then
  MsgBox "The legacy Super Brain launcher cannot open the package-local compatibility UI because this file is missing:" & vbCrLf & vbCrLf & installUiVbs, _
         vbCritical, "Super Brain Control Center"
  WScript.Quit 11
End If

If Not fso.FileExists(installUiPs1) Then
  MsgBox "The legacy Super Brain launcher cannot open the package-local compatibility UI because this file is missing:" & vbCrLf & vbCrLf & installUiPs1, _
         vbCritical, "Super Brain Control Center"
  WScript.Quit 12
End If

exitCode = shell.Run("wscript.exe " & Q(installUiVbs), 0, True)
WScript.Quit exitCode

Function Q(value)
  Q = Chr(34) & value & Chr(34)
End Function
