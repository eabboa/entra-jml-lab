#Requires -Version 7.2
<#
.SYNOPSIS
    Mover: applies HR department/job changes, then moves access from the old department groups to the new ones.
.EXAMPLE
    ./Invoke-Mover.ps1 -CsvPath ../hr/movers.sample.csv -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$AccessMapPath = (Join-Path $PSScriptRoot '..' 'config' 'access-map.csv'),

    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'JmlCommon.psm1') -Force
Connect-JmlGraph -Interactive:$Interactive

$accessMap = @(Import-Csv -Path $AccessMapPath)
$managedGroups = @($accessMap | ForEach-Object GroupName | Sort-Object -Unique)
$rows = @(Import-Csv -Path $CsvPath -Encoding utf8)

foreach ($row in $rows) {
    $employeeId = $row.EmployeeId
    try {
        $user = Get-JmlUserByEmployeeId -EmployeeId $employeeId
        if (-not $user) {
            throw "No account with employeeId $employeeId."
        }
        if (-not $user.AccountEnabled) {
            throw 'Account is disabled. A disabled account is a leaver, not a mover.'
        }

        $oldDepartment = $user.Department
        $desired = @(Get-JmlDesiredGroupName -AccessMap $accessMap -Department $row.NewDepartment)
        $current = @(Get-MgUserMemberOfAsGroup -UserId $user.Id -Property 'id', 'displayName' -All |
                Where-Object { $_.DisplayName -in $managedGroups } |
                ForEach-Object DisplayName)
        $toRemove = @($current | Where-Object { $_ -notin $desired })
        $toAdd = @($desired | Where-Object { $_ -notin $current })

        $attributesChanged = ($oldDepartment -ne $row.NewDepartment) -or ($user.JobTitle -ne $row.NewJobTitle)
        if (-not $attributesChanged -and $toAdd.Count -eq 0 -and $toRemove.Count -eq 0) {
            Write-JmlAudit -Process Mover -EmployeeId $employeeId -UserId $user.Id `
                -Action 'Move' -Result Skipped -Detail 'already in target state'
            continue
        }

        $summary = "$oldDepartment -> $($row.NewDepartment); remove [$($toRemove -join ', ')]; add [$($toAdd -join ', ')]"
        if (-not $PSCmdlet.ShouldProcess($user.UserPrincipalName, $summary)) {
            Write-JmlAudit -Process Mover -EmployeeId $employeeId -UserId $user.Id -Action 'Move' -Result WhatIf -Detail $summary
            continue
        }

        if ($attributesChanged) {
            Update-MgUser -UserId $user.Id -BodyParameter @{ department = $row.NewDepartment; jobTitle = $row.NewJobTitle }
            Write-JmlAudit -Process Mover -EmployeeId $employeeId -UserId $user.Id `
                -Action 'UpdateAttributes' -Result Success -Detail "$oldDepartment -> $($row.NewDepartment)"
        }

        if ($row.NewManagerEmployeeId) {
            $manager = Get-JmlUserByEmployeeId -EmployeeId $row.NewManagerEmployeeId
            if (-not $manager) {
                throw "Manager $($row.NewManagerEmployeeId) not found."
            }
            Set-MgUserManagerByRef -UserId $user.Id -OdataId "https://graph.microsoft.com/v1.0/users/$($manager.Id)"
            Write-JmlAudit -Process Mover -EmployeeId $employeeId -UserId $user.Id `
                -Action 'SetManager' -Result Success -Detail $row.NewManagerEmployeeId
        }

        foreach ($groupName in $toRemove) {
            $group = Resolve-JmlGroup -DisplayName $groupName
            Remove-MgGroupMemberDirectoryObjectByRef -GroupId $group.Id -DirectoryObjectId $user.Id
            Write-JmlAudit -Process Mover -EmployeeId $employeeId -UserId $user.Id `
                -Action 'RemoveGroup' -Result Success -Detail $groupName
        }

        foreach ($groupName in $toAdd) {
            $group = Resolve-JmlGroup -DisplayName $groupName
            New-MgGroupMemberByRef -GroupId $group.Id -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)"
            Write-JmlAudit -Process Mover -EmployeeId $employeeId -UserId $user.Id `
                -Action 'AddGroup' -Result Success -Detail $groupName
        }
    }
    catch {
        Write-JmlAudit -Process Mover -EmployeeId $employeeId -Action 'Mover' -Result Failed -Detail $_.Exception.Message
        Write-Warning "Mover failed for ${employeeId}: $($_.Exception.Message)"
    }
}

Write-Information -MessageData "Mover finished. Audit trail: logs/jml-audit.jsonl" -InformationAction Continue
