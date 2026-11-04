# 0) Bağlan
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
Connect-MgGraph -Scopes "Policy.Read.All","Policy.ReadWrite.ConditionalAccess","User.Read.All","Application.Read.All"

$base = "https://graph.microsoft.com/beta/identity/conditionalAccess"

function Get-UserId($prefix) {
    (Invoke-MgGraphRequest GET "https://graph.microsoft.com/v1.0/users?`$filter=startswith(userPrincipalName,'$prefix')&`$select=id,userPrincipalName").value[0].id
}

$bg1  = Get-UserId "bg-01"
$bg2  = Get-UserId "bg-02"
$fin1 = Get-UserId "fin.user1"

$mfaStrength = "00000000-0000-0000-0000-000000000002"

# 1) CA010 - Report-only
$ca010 = @{
    displayName = "CA010-Global-SignInRisk-MFA"
    state       = "enabledForReportingButNotEnforced"
    conditions  = @{
        users           = @{ includeUsers = @("All"); excludeUsers = @($bg1, $bg2) }
        applications    = @{ includeApplications = @("All") }
        clientAppTypes  = @("all")
        signInRiskLevels = @("high","medium")
    }
    grantControls = @{
        operator               = "OR"
        authenticationStrength = @{ id = $mfaStrength }
    }
    sessionControls = @{
        signInFrequency = @{
            isEnabled          = $true
            frequencyInterval  = "everyTime"
            authenticationType = "primaryAndSecondaryAuthentication"
        }
    }
}
$p010 = Invoke-MgGraphRequest POST "$base/policies" -Body ($ca010 | ConvertTo-Json -Depth 10) -ContentType "application/json"

# 2) CA011 - Report-only
$ca011 = @{
    displayName = "CA011-Global-UserRisk-Remediation"
    state       = "enabledForReportingButNotEnforced"
    conditions  = @{
        users          = @{ includeUsers = @("All"); excludeUsers = @($bg1, $bg2) }
        applications   = @{ includeApplications = @("All") }
        clientAppTypes = @("all")
        userRiskLevels = @("high")
    }
    grantControls = @{
        operator               = "AND"
        builtInControls        = @("riskRemediation")
        authenticationStrength = @{ id = $mfaStrength }
    }
    sessionControls = @{
        signInFrequency = @{
            isEnabled          = $true
            frequencyInterval  = "everyTime"
            authenticationType = "primaryAndSecondaryAuthentication"
        }
    }
}
$p011 = Invoke-MgGraphRequest POST "$base/policies" -Body ($ca011 | ConvertTo-Json -Depth 10) -ContentType "application/json"

# 3) What If
function Test-WhatIf($userId, $signInRisk) {
    $body = @{
        signInIdentity   = @{ "@odata.type" = "#microsoft.graph.userSignIn"; userId = $userId }
        signInContext    = @{ "@odata.type" = "#microsoft.graph.applicationContext"; includeApplications = @("00000003-0000-0000-c000-000000000000") }
        signInConditions = @{ signInRiskLevel = $signInRisk; clientAppType = "browser" }
        appliedPoliciesOnly = $false
    }
    $r = Invoke-MgGraphRequest POST "$base/evaluate" -Body ($body | ConvertTo-Json -Depth 10) -ContentType "application/json"
    $r.value | Where-Object { $_.displayName -like "CA01[01]*" } |
        Select-Object displayName, policyApplies, @{n="reasons";e={$_.analysisReasons}}
}

"--- fin.user1 / Medium (CA010 = True olmalı) ---"
Test-WhatIf $fin1 "medium" | Format-Table -AutoSize
"--- bg-01 / Medium (CA010 ve CA011 = False olmalı) ---"
Test-WhatIf $bg1 "medium" | Format-Table -AutoSize

# 4) Testler doğruysa On
foreach ($id in @($p010.id, $p011.id)) {
    Invoke-MgGraphRequest PATCH "$base/policies/$id" -Body (@{ state = "enabled" } | ConvertTo-Json) -ContentType "application/json"
}

# 5) Microsoft-managed politika: göster
$mm = (Invoke-MgGraphRequest GET "$base/policies").value |
      Where-Object { $_.displayName -like "*Multifactor authentication and reauthentication for risky sign-ins*" }
$mm | ConvertTo-Json -Depth 10
(Invoke-MgGraphRequest GET "$base/policies/$($p010.id)") | ConvertTo-Json -Depth 10

# 5a) Aynı işi yapıyorsa Microsoft-managed olanı kapat
Invoke-MgGraphRequest PATCH "$base/policies/$($mm.id)" -Body (@{ state = "disabled" } | ConvertTo-Json) -ContentType "application/json"

# 5b) Açık bırakacaksan bg-01/bg-02 exclude'a ekle
$ex = @($mm.conditions.users.excludeUsers) + @($bg1, $bg2) | Select-Object -Unique
$patch = @{ conditions = @{ users = @{ excludeUsers = $ex } } }
Invoke-MgGraphRequest PATCH "$base/policies/$($mm.id)" -Body ($patch | ConvertTo-Json -Depth 10) -ContentType "application/json"
(Invoke-MgGraphRequest GET "$base/policies/$($mm.id)").conditions.users.excludeUsers