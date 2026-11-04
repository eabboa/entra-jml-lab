#Requires -Version 7.2
# Test-HrCsv.ps1
# Checks an HR joiner file before any account is created.
# Exit code 0 = file is clean. Exit code 1 = problems found.

param(
    [Parameter(Mandatory)]
    [string]$Path,

    [string[]]$AllowedDepartments = @('Finance', 'Sales', 'IT')
)

if (-not (Test-Path -Path $Path)) {
    Write-Warning "File not found: $Path"
    exit 1
}

$rows = @(Import-Csv -Path $Path -Encoding utf8)

if ($rows.Count -eq 0) {
    Write-Warning "File has no people in it: $Path"
    exit 1
}

$required = @('EmployeeId', 'GivenName', 'Surname', 'Department',
    'JobTitle', 'ManagerEmployeeId', 'HireDate', 'UsageLocation')
$columns = $rows[0].PSObject.Properties.Name
$problems = @()

foreach ($column in $required) {
    if ($column -notin $columns) {
        $problems += "Missing column: $column"
    }
}


if ($problems.Count -eq 0) {

    $duplicates = $rows | Group-Object -Property EmployeeId | Where-Object { $_.Count -gt 1 }
    foreach ($duplicate in $duplicates) {
        $problems += "Duplicate EmployeeId: $($duplicate.Name)"
    }

    $lineNumber = 1
    foreach ($row in $rows) {
        $lineNumber = $lineNumber + 1

        if ([string]::IsNullOrWhiteSpace($row.EmployeeId)) {
            $problems += "Line ${lineNumber}: EmployeeId is empty"
        }
        if ($row.Department -cnotin $AllowedDepartments) {
            $problems += "Line ${lineNumber}: unknown department '$($row.Department)'"
        }
        if ($row.HireDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
            $problems += "Line ${lineNumber}: HireDate '$($row.HireDate)' is not yyyy-MM-dd"
        }
        if ($row.UsageLocation -cnotmatch '^[A-Z]{2}$') {
            $problems += "Line ${lineNumber}: UsageLocation '$($row.UsageLocation)' is not a 2-letter code"
        }
    }
}

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) {
        Write-Warning $problem
    }
    Write-Output "FAILED: $($problems.Count) problem(s) in $Path"
    exit 1
}

Write-Output "OK: $($rows.Count) row(s) valid in $Path"
exit 0

