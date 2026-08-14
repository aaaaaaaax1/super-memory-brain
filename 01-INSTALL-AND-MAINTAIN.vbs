Option Explicit

Dim fso, shell, root, target
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
root = fso.GetParentFolderName(WScript.ScriptFullName)
target = fso.BuildPath(root, "CORE\scripts\install-ui.vbs")

If WScript.Arguments.Count > 0 Then
  If LCase(CStr(WScript.Arguments(0))) = "/probe" Then
    WScript.Echo target
    WScript.Quit 0
  End If
End If

If Not fso.FileExists(target) Then
  MsgBox "Super Memory Brain installer is missing.", 16, "Super Memory Brain"
  WScript.Quit 1
End If

shell.Run "wscript.exe " & Chr(34) & target & Chr(34), 0, False
