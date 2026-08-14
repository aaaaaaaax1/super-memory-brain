Option Explicit

Dim fso, shell, scriptDir, psScript, command, exitCode
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = scriptDir & "\install-ui.ps1"

If Not fso.FileExists(psScript) Then
  MsgBox "The package-local Super Brain control UI is unavailable because this file is missing:" & vbCrLf & vbCrLf & psScript, _
         vbCritical, "Super Brain Control Center"
  WScript.Quit 11
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Q(psScript)
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function Q(value)
  Q = Chr(34) & value & Chr(34)
End Function
