# The administrators group has a different name depending on the image language.
$script:AdminGroupByLanguage = @{
    es = 'Administradores'
    pt = 'Administradores'
    fr = 'Administrateurs'
    de = 'Administratoren'
}

function Get-AdminGroupName {
    param([Parameter(Mandatory)][string]$Language)
    $prefix = $Language.Split('-')[0].ToLowerInvariant()
    if ($script:AdminGroupByLanguage.ContainsKey($prefix)) { $script:AdminGroupByLanguage[$prefix] } else { 'Administrators' }
}

function New-UnattendXml {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$UILanguage,
        [string]$UserLocale = (Get-Culture).Name,
        [string]$InputLocale = (Get-Culture).Name,
        [string]$TimeZone = (Get-TimeZone).Id,
        [bool]$AutoLogon = $true,
        [string]$TemplatePath = (Get-RepoPath 'templates\unattend.xml')
    )
    $plain = [Net.NetworkCredential]::new('', $Password).Password
    $esc = { param($v) [Security.SecurityElement]::Escape([string]$v) }

    $autoLogonXml = ''
    if ($AutoLogon) {
        # Needed so streaming finds a logged-on session after every boot.
        $autoLogonXml = @"
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>$(& $esc $UserName)</Username>
        <Password>
          <Value>$(& $esc $plain)</Value>
          <PlainText>true</PlainText>
        </Password>
        <LogonCount>9999999</LogonCount>
      </AutoLogon>
"@
    }

    $values = @{
        ComputerName = $ComputerName
        TimeZone     = $TimeZone
        InputLocale  = $InputLocale
        SystemLocale = $UILanguage
        UILanguage   = $UILanguage
        UserLocale   = $UserLocale
        UserName     = $UserName
        AdminGroup   = Get-AdminGroupName $UILanguage
        Password     = $plain
    }
    $xml = Get-Content -Raw -LiteralPath $TemplatePath
    foreach ($key in $values.Keys) { $xml = $xml.Replace("{{$key}}", (& $esc $values[$key])) }
    $xml = $xml.Replace('{{AutoLogon}}', $autoLogonXml)

    if ($xml -match '\{\{\w+\}\}') { throw "Quedó un marcador sin reemplazar en unattend.xml: $($Matches[0])" }
    [void][xml]$xml
    $xml
}

# Windows limits the NetBIOS name to 15 characters and to letters, digits and hyphens.
function ConvertTo-ComputerName {
    param([Parameter(Mandatory)][string]$Name)
    $clean = (ConvertTo-Slug $Name).ToUpperInvariant()
    if (-not $clean) { $clean = 'GPUVM' }
    if ($clean.Length -gt 15) { $clean = $clean.Substring(0, 15).TrimEnd('-') }
    $clean
}
