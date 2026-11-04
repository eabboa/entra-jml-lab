#Requires -Modules Microsoft.Graph.Authentication
$ErrorActionPreference = 'Stop'
Connect-MgGraph -Scopes 'EntitlementManagement.ReadWrite.All','Group.ReadWrite.All','User.Read.All' -NoWelcome

$G  = 'https://graph.microsoft.com/v1.0'
$EM = "$G/identityGovernance/entitlementManagement"

$CatalogName = 'Finance-Catalog'
$ScopeGroup  = 'DYN-Dept-Finance'
$FallbackUpn = 'lab-admin'

$Packages = @(
  @{ Name='AP-Finance-Reports';   Group='APP-FinanceReports-Readers'; Question='Hangi rapora ihtiyacın var?' }
  @{ Name='AP-Payments-Initiate'; Group='APP-Payments-Initiators';    Question='Hangi ödemeyi başlatacaksın?' }
  @{ Name='AP-Payments-Approve';  Group='APP-Payments-Approvers';     Question='Hangi ödemeleri onaylayacaksın?' }
)
$Incompatible = @(
  @('AP-Payments-Approve','AP-Payments-Initiate'),
  @('AP-Payments-Initiate','AP-Payments-Approve')
)

function Esc($s){ [uri]::EscapeDataString($s) }
function Get1($u){ Invoke-MgGraphRequest -Method GET -Uri $u }
function Q($u){ (Invoke-MgGraphRequest -Method GET -Uri $u).value }
function Post($u,$b){ Invoke-MgGraphRequest -Method POST -Uri $u -Body ($b | ConvertTo-Json -Depth 20) -ContentType 'application/json' }

function Get-Group($n, [switch]$Create){
  $g = Q "$G/groups?`$filter=$(Esc "displayName eq '$n'")" | Select-Object -First 1
  if(-not $g -and $Create){
    $g = Post "$G/groups" @{ displayName=$n; mailEnabled=$false; mailNickname=($n -replace '[^A-Za-z0-9]',''); securityEnabled=$true }
  }
  if(-not $g){ throw "Grup yok: $n" }
  $g
}

# Catalog
$cat = Q "$EM/catalogs?`$filter=$(Esc "displayName eq '$CatalogName'")" | Select-Object -First 1
if(-not $cat){ $cat = Post "$EM/catalogs" @{ displayName=$CatalogName; description=$CatalogName; isExternallyVisible=$false } }

$scopeGrp = Get-Group $ScopeGroup
$fb = Q "$G/users?`$filter=$(Esc "startswith(userPrincipalName,'$FallbackUpn')")" | Select-Object -First 1
if(-not $fb){ throw "Kullanıcı yok: $FallbackUpn" }

function Get-CatalogResource($groupId){
  $u = "$EM/catalogs/$($cat.id)/resources?`$filter=$(Esc "originId eq '$groupId'")&`$expand=scopes"
  $r = Q $u | Select-Object -First 1
  if(-not $r){
    Post "$EM/resourceRequests" @{ requestType='adminAdd'; resource=@{ originId=$groupId; originSystem='AadGroup' }; catalog=@{ id=$cat.id } } | Out-Null
    for($i=0; $i -lt 20 -and -not $r; $i++){ Start-Sleep 3; $r = Q $u | Select-Object -First 1 }
  }
  if(-not $r){ throw "Kaynak kataloğa eklenmedi: $groupId" }
  $r
}

$ids = @{}
foreach($p in $Packages){
  $grp = Get-Group $p.Group -Create
  $res = Get-CatalogResource $grp.id

  $ap = Q "$EM/accessPackages?`$filter=$(Esc "displayName eq '$($p.Name)'")&`$expand=catalog" | Where-Object { $_.catalog.id -eq $cat.id } | Select-Object -First 1
  if(-not $ap){ $ap = Post "$EM/accessPackages" @{ displayName=$p.Name; description=$p.Name; isHidden=$false; catalog=@{ id=$cat.id } } }
  $ids[$p.Name] = $ap.id

  $full = Get1 "$EM/accessPackages/$($ap.id)?`$expand=resourceRoleScopes(`$expand=role),assignmentPolicies"

  # Resource role: Member
  if(-not ($full.resourceRoleScopes | Where-Object { $_.role.originId -eq "Member_$($grp.id)" })){
    $scope = @{ originId=$grp.id; originSystem='AadGroup' }
    if($res.scopes){ $scope.id = $res.scopes[0].id }
    Post "$EM/accessPackages/$($ap.id)/resourceRoleScopes" @{
      role  = @{ originId="Member_$($grp.id)"; displayName='Member'; originSystem='AadGroup'
                 resource=@{ id=$res.id; originId=$grp.id; originSystem='AadGroup' } }
      scope = $scope
    } | Out-Null
  }

  # Policy
  if(-not $full.assignmentPolicies){
    Post "$EM/assignmentPolicies" @{
      displayName            = "$($p.Name)-Policy"
      description            = 'DYN-Dept-Finance, manager approval, 7 days'
      allowedTargetScope     = 'specificDirectoryUsers'
      specificAllowedTargets = @(@{ '@odata.type'='#microsoft.graph.groupMembers'; groupId=$scopeGrp.id; description=$ScopeGroup })
      expiration             = @{ type='afterDuration'; duration='P7D' }
      requestorSettings      = @{
        enableTargetsToSelfAddAccess=$true; enableTargetsToSelfUpdateAccess=$false; enableTargetsToSelfRemoveAccess=$true
        allowCustomAssignmentSchedule=$true
        enableOnBehalfRequestorsToAddAccess=$false; enableOnBehalfRequestorsToUpdateAccess=$false; enableOnBehalfRequestorsToRemoveAccess=$false
        onBehalfRequestors=@()
      }
      requestApprovalSettings = @{
        isApprovalRequiredForAdd=$true; isApprovalRequiredForUpdate=$false; isRequestorJustificationRequired=$true
        stages = @(@{
          durationBeforeAutomaticDenial='P3D'; isApproverJustificationRequired=$true; isEscalationEnabled=$false
          primaryApprovers         = @(@{ '@odata.type'='#microsoft.graph.requestorManager'; managerLevel=1 })
          fallbackPrimaryApprovers = @(@{ '@odata.type'='#microsoft.graph.singleUser'; userId=$fb.id; description=$fb.userPrincipalName })
        })
      }
      questions = @(@{ '@odata.type'='#microsoft.graph.accessPackageTextInputQuestion'; sequence=1; isRequired=$true; isAnswerEditable=$true; isSingleLineQuestion=$false; text=$p.Question })
      accessPackage = @{ id=$ap.id }
    } | Out-Null
  }
  Write-Host "OK  $($p.Name)"
}

# Separation of duties
foreach($pair in $Incompatible){
  $a = $ids[$pair[0]]; $b = $ids[$pair[1]]
  if(-not (Q "$EM/accessPackages/$a/incompatibleAccessPackages" | Where-Object { $_.id -eq $b })){
    Post "$EM/accessPackages/$a/incompatibleAccessPackages/`$ref" @{ '@odata.id'="$EM/accessPackages/$b" } | Out-Null
  }
  Write-Host "SoD $($pair[0]) <-> $($pair[1])"
}