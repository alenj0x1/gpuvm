; The GpuVM service (gpuvm-host.exe) does the Hyper-V work for the app, which runs without administrator.

!macro NSIS_HOOK_PREINSTALL
  ; Updating: stop the service so its files can be replaced (its PowerShell bridges stop with it).
  IfFileExists "$INSTDIR\gpuvm-host.exe" 0 +2
    nsExec::Exec '"$INSTDIR\gpuvm-host.exe" stop'
!macroend

!macro NSIS_HOOK_POSTINSTALL
  nsExec::Exec '"$INSTDIR\gpuvm-host.exe" install'
  Pop $0
  StrCmp $0 "0" +2
    MessageBox MB_ICONEXCLAMATION "No se pudo registrar el servicio de GpuVM. Abre GpuVM y elige «Reparar»."
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  IfFileExists "$INSTDIR\gpuvm-host.exe" 0 +2
    nsExec::Exec '"$INSTDIR\gpuvm-host.exe" uninstall'
!macroend
