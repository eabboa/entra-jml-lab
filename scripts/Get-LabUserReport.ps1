#Requires -Version 7.2
<#
.SYNOPSIS
    Read-only report: every member user with HR attributes and manager, exported to CSV.
.EXAMPLE
    ./Get-LabUserReport.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path $PSScriptRoot '..' 'out' 'user-report.csv')
)

$ErrorActionPreference = 'Stop'
Connect-MgGraph -Scopes 'User.Read.All' -NoWelcome

$properties = 'id', 'displayName', 'userPrincipalName', 'department', 'jobTitle',
'employeeId', 'employeeHireDate', 'accountEnabled'

$users = Get-MgUser -Filter "userType eq 'Member'" -Property $properties `
    -ExpandProperty 'manager($select=displayName)' -All

$report = $users | Select-Object DisplayName, UserPrincipalName, Department, JobTitle,
EmployeeId, EmployeeHireDate, AccountEnabled,
@{ Name = 'Manager'; Expression = { $_.Manager.AdditionalProperties['displayName'] } }

$outDir = Split-Path -Path $OutFile -Parent
if (-not (Test-Path -Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
$report | Sort-Object Department, DisplayName | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8

$missing = @($report | Where-Object { -not $_.Department -or -not $_.EmployeeId -or -not $_.Manager })
Write-Information -MessageData "Exported $($report.Count) users to $OutFile" -InformationAction Continue
Write-Information -MessageData "Users missing department, employeeId or manager: $($missing.Count)" -InformationAction Continue