@echo off

:checkAdminPriv
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"

if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
echo Set UAC = CreateObject^("Shell.Application"^) > "getadmin.vbs"
set params = %*:"=""
echo UAC.ShellExecute "cmd.exe", "/c cd %cd% && %~s0 %params%", "", "runas", 1 >> "getadmin.vbs"

"getadmin.vbs"
del "getadmin.vbs"
exit /B

:gotAdmin

dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

echo downloading wsl_update_x64...
curl.exe -LSfs --remote-name --remove-on-error https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi
wsl_update_x64.msi
del "wsl_update_x64.msi"

wsl --set-default-version 2

echo a system reboot might be required
echo Press any key to exit . . .
pause>nul
