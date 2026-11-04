#Requires -Version 7.2
<#
.SYNOPSIS
    Joiner: creates cloud accounts from an HR CSV, sets the manager and adds baseline access groups.
.EXAMPLE
    ./Invoke-Joiner.ps1 -CsvPath ../hr/joiners.sample.csv -UpnDomain contoso.onmicrosoft.com -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$UpnDomain,

    [string]$AccessMapPath = (Join-Path $PSScriptRoot '..' 'config' 'access-map.csv'),

    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JmlCommon.psm1') -Force
Connect-JmlGraph -Interactive:$Interactive

$isDelegated = (Get-MgContext).AuthType -eq 'Delegated'
$accessMap = @(Import-Csv -Path $AccessMapPath)
$rows = @(Import-Csv -Path $CsvPath -Encoding utf8)

foreach ($row in $rows) {
    $employeeId = $row.EmployeeId
    try {
        $existing = Get-JmlUserByEmployeeId -EmployeeId $employeeId
        if ($existing) {
            Write-JmlAudit -Process Joiner -EmployeeId $employeeId -UserId $existing.Id `
                -Action 'CreateUser' -Result Skipped -Detail 'employeeId already exists'
            continue
        }

        $upn = Get-JmlFreeUpn -GivenName $row.GivenName -Surname $row.Surname -Domain $UpnDomain
        $hireDate = [datetime]::ParseExact($row.HireDate, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
        $body = @{
            accountEnabled    = $true
            displayName       = "$($row.GivenName) $($row.Surname)"
            givenName         = $row.GivenName
            surname           = $row.Surname
            userPrincipalName = $upn
            mailNickname      = $upn.Split('@')[0]
            department        = $row.Department
            jobTitle          = $row.JobTitle
            employeeId        = $employeeId
            usageLocation     = $row.UsageLocation
            passwordProfile   = @{
                forceChangePasswordNextSignIn = $true
                password                      = Get-JmlRandomPassword
            }
        }
        if ($isDelegated) {
            $body.employeeHireDate = $hireDate.ToString('yyyy-MM-ddT00:00:00Z')
        }

        if (-not $PSCmdlet.ShouldProcess($upn, 'Create user, set manager, add groups')) {
            Write-JmlAudit -Process Joiner -EmployeeId $employeeId -Action 'CreateUser' -Result WhatIf -Detail $upn
            continue
        }

        $user = New-MgUser -BodyParameter $body
        Write-JmlAudit -Process Joiner -EmployeeId $employeeId -UserId $user.Id `
            -Action 'CreateUser' -Result Success -Detail $upn
        if (-not $isDelegated) {
            Write-JmlAudit -Process Joiner -EmployeeId $employeeId -UserId $user.Id -Action 'SetHireDate' `
                -Result Skipped -Detail 'app-only cannot write employeeHireDate; HR provisioning or a delegated run sets it'
        }

        if ($row.ManagerEmployeeId) {
            $manager = Get-JmlUserByEmployeeId -EmployeeId $row.ManagerEmployeeId
            if ($manager) {
                Set-MgUserManagerByRef -UserId $user.Id -OdataId "https://graph.microsoft.com/v1.0/users/$($manager.Id)"
                Write-JmlAudit -Process Joiner -EmployeeId $employeeId -UserId $user.Id `
                    -Action 'SetManager' -Result Success -Detail $row.ManagerEmployeeId
            }
            else {
                Write-JmlAudit -Process Joiner -EmployeeId $employeeId -UserId $user.Id `
                    -Action 'SetManager' -Result Failed -Detail "manager $($row.ManagerEmployeeId) not found"
            }
        }

        foreach ($groupName in (Get-JmlDesiredGroupName -AccessMap $accessMap -Department $row.Department)) {
            $group = Resolve-JmlGroup -DisplayName $groupName
            New-MgGroupMemberByRef -GroupId $group.Id -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)"
            Write-JmlAudit -Process Joiner -EmployeeId $employeeId -UserId $user.Id `
                -Action 'AddGroup' -Result Success -Detail $groupName
        }
    }
    catch {
        Write-JmlAudit -Process Joiner -EmployeeId $employeeId -Action 'Joiner' -Result Failed -Detail $_.Exception.Message
        Write-Warning "Joiner failed for ${employeeId}: $($_.Exception.Message)"
    }
}

Write-Information -MessageData "Joiner finished. Audit trail: logs/jml-audit.jsonl" -InformationAction Continue