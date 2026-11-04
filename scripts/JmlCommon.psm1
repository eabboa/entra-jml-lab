#Requires -Version 7.2
# JmlCommon.psm1 - shared helpers for Invoke-Joiner, Invoke-Mover and Invoke-Leaver.
Set-StrictMode -Version Latest

$script:GroupCache = @{}

function Connect-JmlGraph {
    [CmdletBinding()]
    param(
        [switch]$Interactive
    )
    if ($Interactive) {
        $scopes = 'User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'User.RevokeSessions.All'
        Connect-MgGraph -Scopes $scopes -NoWelcome -ErrorAction Stop
    }
    else {
        foreach ($name in 'JML_TENANT_ID', 'JML_CLIENT_ID', 'JML_CERT_THUMBPRINT') {
            if (-not [Environment]::GetEnvironmentVariable($name)) {
                throw "Environment variable $name is missing. See README > Setup."
            }
        }
        Connect-MgGraph -TenantId $env:JML_TENANT_ID -ClientId $env:JML_CLIENT_ID `
            -CertificateThumbprint $env:JML_CERT_THUMBPRINT -NoWelcome -ErrorAction Stop
    }
}

function Write-JmlAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Joiner', 'Mover', 'Leaver')][string]$Process,
        [Parameter(Mandatory)][string]$EmployeeId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Success', 'Skipped', 'Failed', 'WhatIf')][string]$Result,
        [string]$UserId = '',
        [string]$Detail = ''
    )
    $logDir = Join-Path $PSScriptRoot '..' 'logs'
    if (-not (Test-Path -Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -WhatIf:$false | Out-Null
    }
    $context = Get-MgContext
    $actor = if ($null -eq $context) { 'not-connected' }
    elseif ($context.Account) { $context.Account }
    else { "app:$($context.AppName)" }
    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        process      = $Process
        employeeId   = $EmployeeId
        userId       = $UserId
        action       = $Action
        result       = $Result
        detail       = $Detail
        actor        = $actor
    }
    $entry | ConvertTo-Json -Compress |
        Add-Content -Path (Join-Path $logDir 'jml-audit.jsonl') -Encoding utf8 -WhatIf:$false
}

function Get-JmlUserByEmployeeId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EmployeeId)
    $safeId = $EmployeeId.Replace("'", "''")
    $properties = 'id', 'displayName', 'userPrincipalName', 'department', 'jobTitle', 'employeeId', 'accountEnabled'
    $found = @(Get-MgUser -Filter "employeeId eq '$safeId'" -Property $properties `
            -ConsistencyLevel eventual -CountVariable matchCount -All)
    if ($found.Count -gt 1) {
        throw "employeeId '$EmployeeId' matches $($found.Count) accounts. Fix the HR data first."
    }
    return $found | Select-Object -First 1
}

function ConvertTo-JmlAsciiName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Text)
    $decomposed = $Text.Replace([char]0x0131, 'i').Normalize([Text.NormalizationForm]::FormD)
    $builder = [Text.StringBuilder]::new()
    foreach ($char in $decomposed.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }
    return ($builder.ToString().ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Get-JmlFreeUpn {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname,
        [Parameter(Mandatory)][string]$Domain
    )
    $base = '{0}.{1}' -f (ConvertTo-JmlAsciiName -Text $GivenName), (ConvertTo-JmlAsciiName -Text $Surname)
    $candidate = "$base@$Domain"
    $suffix = 1
    while (Get-MgUser -Filter "userPrincipalName eq '$candidate'" -Property 'id' -Top 1) {
        $suffix++
        $candidate = "$base$suffix@$Domain"
    }
    return $candidate
}

function Get-JmlRandomPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(16, 128)][int]$Length = 24)
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%*-_'.ToCharArray()
    do {
        $bytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes($Length)
        $password = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    } until ($password -cmatch '[a-z]' -and $password -cmatch '[A-Z]' -and
        $password -match '\d' -and $password -match '[^a-zA-Z0-9]')
    return $password
}

function Get-JmlDesiredGroupName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][object[]]$AccessMap,
        [Parameter(Mandatory)][string]$Department
    )
    $AccessMap |
        Where-Object { $_.Department -eq '*' -or $_.Department -eq $Department } |
        ForEach-Object GroupName |
        Sort-Object -Unique
}

function Resolve-JmlGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DisplayName)
    if (-not $script:GroupCache.ContainsKey($DisplayName)) {
        $safeName = $DisplayName.Replace("'", "''")
        $groups = @(Get-MgGroup -Filter "displayName eq '$safeName'" `
                -Property 'id', 'displayName', 'groupTypes', 'isAssignableToRole' -All)
        if ($groups.Count -ne 1) {
            throw "Expected exactly one group named '$DisplayName', found $($groups.Count)."
        }
        $script:GroupCache[$DisplayName] = $groups[0]
    }
    return $script:GroupCache[$DisplayName]
}

Export-ModuleMember -Function Connect-JmlGraph, Write-JmlAudit, Get-JmlUserByEmployeeId,
ConvertTo-JmlAsciiName, Get-JmlFreeUpn, Get-JmlRandomPassword, Get-JmlDesiredGroupName, Resolve-JmlGroup