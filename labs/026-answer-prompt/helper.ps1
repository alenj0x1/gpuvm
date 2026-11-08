# Lab 026, guest side, step 2: runs as SYSTEM in the signed-in user's session on the secure desktop (winsta0\winlogon,
# where Windows draws administrator prompts), started by launcher.ps1. Reads the prompt with UI Automation and,
# with -Action yes/no, presses that button. Writes what it found to -Out as JSON. Windows PowerShell 5.1.
param(
    [ValidateSet('read', 'yes', 'no')][string]$Action = 'read',
    [string]$Out = 'C:\GpuVM\lab026-helper.json'
)
$result = [ordered]@{ action = $Action; windows = @(); pressed = $null; error = $null }
try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $A = [System.Windows.Automation.AutomationElement]
    $T = [System.Windows.Automation.TreeScope]
    $root = $A::RootElement
    $buttonType = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $textType = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $target = $null
    foreach ($w in $root.FindAll($T::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
        $buttons = @($w.FindAll($T::Descendants, $buttonType) | ForEach-Object { [ordered]@{ name = $_.Current.Name; id = $_.Current.AutomationId } })
        $texts = @($w.FindAll($T::Descendants, $textType) | ForEach-Object { $_.Current.Name } | Where-Object { $_ })
        $result.windows += [ordered]@{ name = $w.Current.Name; class = $w.Current.ClassName; texts = $texts; buttons = $buttons }
        if ($w.Current.ClassName -like 'Credential Dialog Xaml Host*') { $target = $w }
    }
    if ($Action -ne 'read') {
        if (-not $target) { throw 'No administrator prompt on the secure desktop.' }
        $want = if ($Action -eq 'yes') { 'OkButton' } else { 'CancelButton' }
        $button = $target.FindAll($T::Descendants, $buttonType) | Where-Object { $_.Current.AutomationId -eq $want } | Select-Object -First 1
        if (-not $button) { throw "Button $want not found." }
        $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $result.pressed = $want
    }
}
catch { $result.error = $_.Exception.Message }
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Out -Encoding UTF8
