#Requires -Version 7.2
<#
.SYNOPSIS
    Leaver: disables the account, revokes sessions, removes group access and writes an audit record.
.EXAMPLE
    ./Invoke-Leaver.ps1 -CsvPath ../hr/leavers.sample.csv -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JmlCommon.psm1') -Force
Connect-JmlGraph -Interactive:$Interactive

$rows = @(Import-Csv -Path $CsvPath -Encoding utf8)

foreach ($row in $rows) {
    $employeeId = $row.EmployeeId
    try {
        $user = Get-JmlUserByEmployeeId -EmployeeId $employeeId
        if (-not $user) {
            throw "No account with employeeId $employeeId."
        }

        $groups = @(Get-MgUserMemberOfAsGroup -UserId $user.Id `
                -Property 'id', 'displayName', 'groupTypes', 'isAssignableToRole' -All)
        $dynamic = @($groups | Where-Object { $_.GroupTypes -contains 'DynamicMembership' })
        $roleAssignable = @($groups | Where-Object { $_.IsAssignableToRole })
        $removable = @($groups | Where-Object {
                $_.GroupTypes -notcontains 'DynamicMembership' -and -not $_.IsAssignableToRole })

        if (-not $user.AccountEnabled -and $removable.Count -eq 0) {
            Write-JmlAudit -Process Leaver -EmployeeId $employeeId -UserId $user.Id `
                -Action 'Offboard' -Result Skipped -Detail 'already disabled, no removable groups'
            continue
        }

        $plan = "disable, revoke sessions, remove $($removable.Count) group(s)"
        if (-not $PSCmdlet.ShouldProcess($user.UserPrincipalName, $plan)) {
            Write-JmlAudit -Process Leaver -EmployeeId $employeeId -UserId $user.Id `
                -Action 'Offboard' -Result WhatIf -Detail "$plan [$($removable.DisplayName -join ', ')]"
            continue
        }

        Update-MgUser -UserId $user.Id -BodyParameter @{ accountEnabled = $false }
        Write-JmlAudit -Process Leaver -EmployeeId $employeeId -UserId $user.Id -Action 'DisableAccount' -Result Success

        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        Write-JmlAudit -Process Leaver -EmployeeId $employeeId -UserId $user.Id -Action 'RevokeSessions' -Result Success

        foreach ($group in $removable) {
            Remove-MgGroupMemberDirectoryObjectByRef -GroupId $group.Id -DirectoryObjectId $user.Id
            Write-JmlAudit -Process Leaver -EmployeeId $employeeId -UserId $user.Id `
                -Action 'RemoveGroup' -Result Success -Detail $group.DisplayName
        }
        foreach ($group in $dynamic) {
            Write-JmlAudit -Process Leaver -EmployeeId $employeeId -UserId $user.Id `
                -Action 'RemoveGroup' -Result Skipped -Detail "$($group.DisplayName): dynamic, rule drops disabled accounts"
        }
        foreach ($group in $roleAssignable) {
            Write-JmlAudit -Process Leaver -EmployeeId $employeeId -UserId $user.Id `
                -Action 'RemoveGroup' -Result Skipped -Detail "$($group.DisplayName): role-assignable, use the privileged process"
        }

        Write-JmlAudit -Process Leaver -EmployeeId $employeeId -UserId $user.Id -Action 'Offboard' -Result Success `
            -Detail "leaveDate=$($row.LeaveDate); removed=$($removable.Count); skipped=$($dynamic.Count + $roleAssignable.Count)"
    }
    catch {
        Write-JmlAudit -Process Leaver -EmployeeId $employeeId -Action 'Leaver' -Result Failed -Detail $_.Exception.Message
        Write-Warning "Leaver failed for ${employeeId}: $($_.Exception.Message)"
    }
}

Write-Information -MessageData "Leaver finished. Audit trail: logs/jml-audit.jsonl" -InformationAction Continue