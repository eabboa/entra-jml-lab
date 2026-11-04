# Entra CA000-CA006 hepsi Report-only + Microsoft-managed politikalara bg-01/bg-02 exclude
# Calistir: pwsh ./entra-ca-policies.ps1   (Microsoft.Graph.Authentication modulu yeterli)
# Ilk kez: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

Connect-MgGraph -Scopes "Policy.ReadWrite.ConditionalAccess","Policy.Read.All","Application.Read.All","User.Read.All","RoleManagement.Read.Directory" -NoWelcome

$base  = "https://graph.microsoft.com/v1.0"
$state = "enabledForReportingButNotEnforced"   # Report-only

function J($o) { $o | ConvertTo-Json -Depth 20 }

# ---- bg-01 / bg-02 ----
$bg = @()
foreach ($n in "bg-01","bg-02") {
    $r = Invoke-MgGraphRequest -Method GET -Uri "$base/users?`$filter=displayName eq '$n'&`$select=id,displayName"
    if ($r.value.Count -ne 1) { throw "$n bulunamadi veya birden fazla ($($r.value.Count)). displayName'i kontrol et." }
    $bg += $r.value[0].id
}
Write-Host "bg exclude IDs: $($bg -join ', ')"

# ---- Admin rolleri (CA002 / CA003) ----
$roleNames = @(
 "Global Administrator","Privileged Role Administrator","Privileged Authentication Administrator",
 "Security Administrator","Conditional Access Administrator","User Administrator","Groups Administrator",
 "Authentication Administrator","Authentication Policy Administrator","Application Administrator",
 "Helpdesk Administrator","Identity Governance Administrator","Lifecycle Workflows Administrator","License Administrator"
)
$tpl = (Invoke-MgGraphRequest -Method GET -Uri "$base/directoryRoleTemplates").value
$roleIds = @()
foreach ($rn in $roleNames) {
    $m = $tpl | Where-Object { $_.displayName -eq $rn }
    if ($m) { $roleIds += $m.id } else { Write-Warning "Rol sablonu bulunamadi: $rn" }
}

# ---- Named location (CA004) ----
$loc = (Invoke-MgGraphRequest -Method GET -Uri "$base/identity/conditionalAccess/namedLocations?`$filter=displayName eq 'LOC-Allowed-Countries'").value
$locId = if ($loc.Count -eq 1) { $loc[0].id } else { $null }
if (-not $locId) { Write-Warning "LOC-Allowed-Countries bulunamadi, CA004 atlanacak." }

# ---- Authentication strength ID'leri (built-in) ----
$MFA = "00000000-0000-0000-0000-000000000002"
$PHR = "00000000-0000-0000-0000-000000000004"

function Users-All  { @{ includeUsers = @("All"); excludeUsers = $bg } }
function Users-Admin { @{ includeRoles = $roleIds; excludeUsers = $bg } }
$allApps = @{ includeApplications = @("All") }

$policies = @(
 @{ displayName="CA000-Global-BlockLegacyAuth"
    conditions=@{ users=(Users-All); applications=$allApps; clientAppTypes=@("exchangeActiveSync","other") }
    grantControls=@{ operator="OR"; builtInControls=@("block") } },

 @{ displayName="CA001-Global-MFA"
    conditions=@{ users=(Users-All); applications=$allApps; clientAppTypes=@("all") }
    grantControls=@{ operator="OR"; authenticationStrength=@{ id=$MFA } } },

 @{ displayName="CA002-Admins-PhishingResistant"
    conditions=@{ users=(Users-Admin); applications=$allApps; clientAppTypes=@("all") }
    grantControls=@{ operator="OR"; authenticationStrength=@{ id=$PHR } } },

 @{ displayName="CA003-Admins-SignInFrequency"
    conditions=@{ users=(Users-Admin); applications=$allApps; clientAppTypes=@("all") }
    sessionControls=@{
        signInFrequency=@{ isEnabled=$true; type="hours"; value=4; frequencyInterval="timeBased"; authenticationType="primaryAndSecondaryAuthentication" }
        persistentBrowser=@{ isEnabled=$true; mode="never" } } },

 @{ displayName="CA005-Global-SecureRegistration"
    conditions=@{ users=(Users-All); applications=@{ includeUserActions=@("urn:user:registersecurityinfo") }; clientAppTypes=@("all") }
    grantControls=@{ operator="OR"; authenticationStrength=@{ id=$MFA } } },

 @{ displayName="CA006-Global-BlockDeviceCode"
    conditions=@{ users=(Users-All); applications=$allApps; clientAppTypes=@("all"); authenticationFlows=@{ transferMethods="deviceCodeFlow" } }
    grantControls=@{ operator="OR"; builtInControls=@("block") } }
)

if ($locId) {
    $policies += @{ displayName="CA004-Global-BlockOutsideAllowedCountries"
        conditions=@{ users=(Users-All); applications=$allApps; clientAppTypes=@("all")
                      locations=@{ includeLocations=@("All"); excludeLocations=@($locId) } }
        grantControls=@{ operator="OR"; builtInControls=@("block") } }
}

# ---- Olustur (varsa atla) ----
foreach ($p in $policies) {
    $exists = (Invoke-MgGraphRequest -Method GET -Uri "$base/identity/conditionalAccess/policies?`$filter=displayName eq '$($p.displayName)'").value
    if ($exists.Count -gt 0) { Write-Host "ATLANDI (var): $($p.displayName)"; continue }
    $p.state = $state
    try {
        Invoke-MgGraphRequest -Method POST -Uri "$base/identity/conditionalAccess/policies" -Body (J $p) -ContentType "application/json" | Out-Null
        Write-Host "OLUSTU: $($p.displayName)"
    } catch { Write-Warning "HATA $($p.displayName): $($_.Exception.Message)" }
}

# ---- Microsoft-managed politikalara bg exclude ----
$all = (Invoke-MgGraphRequest -Method GET -Uri "$base/identity/conditionalAccess/policies").value
foreach ($mp in ($all | Where-Object { $_.displayName -like "Microsoft-managed:*" })) {
    $u = $mp.conditions.users
    $ex = @($u.excludeUsers) + $bg | Where-Object { $_ } | Select-Object -Unique
    $body = @{ conditions = @{ users = @{
        includeUsers  = @($u.includeUsers);  excludeUsers  = @($ex)
        includeGroups = @($u.includeGroups); excludeGroups = @($u.excludeGroups)
        includeRoles  = @($u.includeRoles);  excludeRoles  = @($u.excludeRoles) } } }
    try {
        Invoke-MgGraphRequest -Method PATCH -Uri "$base/identity/conditionalAccess/policies/$($mp.id)" -Body (J $body) -ContentType "application/json" | Out-Null
        Write-Host "BG EXCLUDE EKLENDI: $($mp.displayName)"
    } catch { Write-Warning "HATA $($mp.displayName): $($_.Exception.Message)" }
}

Write-Host "`nBitti. Entra > Conditional Access > Policies'te State sutununda 'Report-only' yazmali."
