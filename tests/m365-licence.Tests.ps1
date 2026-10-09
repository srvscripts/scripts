# Pester 5 tests for the licence-preservation decisions in m365-user-offboarding (Invoke-M365Offboarding.ps1).
# Only the decision functions are loaded (from the script's syntax tree); nothing connects to Microsoft Graph or
# Exchange Online and no tenant is needed. These are mocks of tenant data, not a live-tenant apply test.
# Run from the repository root:  Invoke-Pester tests/m365-licence.Tests.ps1

BeforeAll {
    $path = Join-Path $PSScriptRoot '../m365-user-offboarding/Invoke-M365Offboarding.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path).Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Parse errors in $path" }
    $names = 'Get-Value', 'Test-ExchangePlanName', 'Get-LicenseInfo', 'Get-MailboxValue', 'Get-MailboxLicenseReason', 'Get-LicensePreservationPlan'
    $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $n.Name }, $false)
    if (@($defs).Count -ne $names.Count) { throw "Expected $($names.Count) decision functions, found $(@($defs).Count)" }
    foreach ($d in $defs) { . ([scriptblock]::Create(($d.Extent.Text -replace '^function\s+', 'function global:'))) }

    function global:New-Lic([string]$Group = '', [object]$Plans = @('EXCHANGE_S_ENTERPRISE'), [string]$State = 'Active', [string]$Sku = 'sku-e3') {
        [pscustomobject]@{ SkuId = $Sku; SkuPartNumber = 'ENTERPRISEPACK'; AssignedByGroup = $Group; State = $State; ExchangePlans = $Plans }
    }
    function global:New-Mbx([hashtable]$Change = @{}) {
        $m = [ordered]@{ LitigationHoldEnabled = $false; ComplianceTagHoldApplied = $false; DelayHoldApplied = $false
            DelayReleaseHoldApplied = $false; InPlaceHolds = @(); ArchiveStatus = 'None'; ArchiveGuid = [guid]::Empty.ToString() }
        foreach ($k in $Change.Keys) { $m[$k] = $Change[$k] }
        [pscustomobject]$m
    }
    $global:Clean = @(Get-MailboxLicenseReason (New-Mbx) 1GB @() $true)
    $global:OnHold = @(Get-MailboxLicenseReason (New-Mbx @{ LitigationHoldEnabled = $true }) 1GB @() $true)
}

Describe 'Mailbox reasons' {
    It 'a converted, small mailbox with no holds and no archive needs no licence' { $Clean.Count | Should -Be 0 }
    It 'litigation hold is a reason' { @($OnHold | Where-Object Code -eq 'Hold').Count | Should -Be 1 }
    It 'unknown mailbox facts are a reason (fail closed)' {
        @(Get-MailboxLicenseReason $null 1GB @() $true | Where-Object Code -eq 'Unknown').Count | Should -BeGreaterThan 0
    }
    It 'unknown size and unknown org policies are reasons' {
        $r = @(Get-MailboxLicenseReason (New-Mbx) $null $null $true)
        @($r | Where-Object Code -eq 'Unknown').Count | Should -Be 2
    }
    It 'an org-wide policy the mailbox is excluded from is not a hold' {
        @(Get-MailboxLicenseReason (New-Mbx @{ InPlaceHolds = @('-mbxabc123:2') }) 1GB @('mbxabc123:2') $true).Count | Should -Be 0
    }
    It 'an archive is a reason' {
        @(Get-MailboxLicenseReason (New-Mbx @{ ArchiveStatus = 'Active' }) 1GB @() $true | Where-Object Code -eq 'Archive').Count | Should -Be 1
    }
    It 'over 50 GB is a reason' {
        @(Get-MailboxLicenseReason (New-Mbx) 60GB @() $true | Where-Object Code -eq 'Size').Count | Should -Be 1
    }
}

Describe 'Licence rows' {
    It 'disabled Exchange plans and Exchange Foundation do not count as Exchange' {
        $skuPlans = @{ 'sku-e3' = @([pscustomobject]@{ Name = 'EXCHANGE_S_ENTERPRISE'; Id = 'p1' }, [pscustomobject]@{ Name = 'EXCHANGE_S_FOUNDATION'; Id = 'p2' }) }
        $states = @(@{ skuId = 'sku-e3'; disabledPlans = @('p1'); assignedByGroup = $null; state = 'Active' })
        $row = @(Get-LicenseInfo $states @{ 'sku-e3' = 'ENTERPRISEPACK' } $skuPlans)[0]
        @($row.ExchangePlans).Count | Should -Be 0
    }
    It 'unreadable SKU details give ExchangePlans $null (treated as Exchange)' {
        $row = @(Get-LicenseInfo @(@{ skuId = 'sku-x'; state = 'Active' }) @{} @{})[0]
        $null -eq $row.ExchangePlans | Should -BeTrue
    }
}

Describe 'Effective licence preservation' {
    It 'group-only Exchange licence on a mailbox under hold: the group is kept' {
        $l = @(New-Lic -Group 'g1')
        $p = Get-LicensePreservationPlan $l $l $OnHold $false $false
        $p.NeedsLicense | Should -BeTrue
        $p.ReplacementVerified | Should -BeFalse
        $p.ProtectedGroupIds | Should -Contain 'g1'
    }
    It 'mixed: an active direct licence with the same Exchange plans is a verified replacement' {
        $l = @((New-Lic -Group 'g1'), (New-Lic -Sku 'sku-direct'))
        $p = Get-LicensePreservationPlan $l $l $OnHold $false $false
        $p.ReplacementVerified | Should -BeTrue
        @($p.ProtectedGroupIds).Count | Should -Be 0
    }
    It 'mixed: a direct licence with different Exchange plans is not a replacement' {
        $l = @((New-Lic -Group 'g1'), (New-Lic -Sku 'sku-direct' -Plans @('EXCHANGE_S_STANDARD')))
        $p = Get-LicensePreservationPlan $l $l $OnHold $false $false
        $p.ReplacementVerified | Should -BeFalse
        $p.ProtectedGroupIds | Should -Contain 'g1'
    }
    It 'mixed: a suspended direct licence is not a replacement' {
        $l = @((New-Lic -Group 'g1'), (New-Lic -Sku 'sku-direct' -State 'Suspended'))
        (Get-LicensePreservationPlan $l $l $OnHold $false $false).ProtectedGroupIds | Should -Contain 'g1'
    }
    It 'failed re-read of licences: nothing is verified, the group is kept' {
        $l = @((New-Lic -Group 'g1'), (New-Lic -Sku 'sku-direct'))
        $p = Get-LicensePreservationPlan $l $null $OnHold $false $false
        $p.ReplacementVerified | Should -BeFalse
        $p.ProtectedGroupIds | Should -Contain 'g1'
    }
    It 'unknown Exchange plans on the group licence: kept (fail closed)' {
        $l = @(New-Lic -Group 'g1' -Plans $null)
        (Get-LicensePreservationPlan $l $l $OnHold $false $false).ProtectedGroupIds | Should -Contain 'g1'
    }
    It 'unknown mailbox facts with a group licence: kept' {
        $l = @(New-Lic -Group 'g1')
        $r = @(Get-MailboxLicenseReason $null $null $null $true)
        (Get-LicensePreservationPlan $l $l $r $false $false).ProtectedGroupIds | Should -Contain 'g1'
    }
    It 'no remaining reason: nothing is protected and licences may be removed' {
        $l = @(New-Lic -Group 'g1')
        $p = Get-LicensePreservationPlan $l $l $Clean $false $false
        $p.NeedsLicense | Should -BeFalse
        @($p.ProtectedGroupIds).Count | Should -Be 0
    }
    It '-ForceLicenseRemoval overrides only "not converted"' {
        $l = @(New-Lic -Group 'g1')
        $notConv = @(Get-MailboxLicenseReason (New-Mbx) 1GB @() $false)
        (Get-LicensePreservationPlan $l $l $notConv $true $false).NeedsLicense | Should -BeFalse
        $notConvHold = @(Get-MailboxLicenseReason (New-Mbx @{ LitigationHoldEnabled = $true }) 1GB @() $false)
        (Get-LicensePreservationPlan $l $l $notConvHold $true $false).NeedsLicense | Should -BeTrue
    }
    It '-SkipLicenseRemoval keeps every licence group, Exchange or not' {
        $l = @((New-Lic -Group 'g1'), (New-Lic -Group 'g2' -Plans @() -Sku 'sku-visio'))
        $p = Get-LicensePreservationPlan $l $l $Clean $false $true
        $p.ProtectedGroupIds | Should -Contain 'g1'
        $p.ProtectedGroupIds | Should -Contain 'g2'
    }
    It 'a non-Exchange group licence is not protected when the mailbox needs a licence' {
        $l = @((New-Lic -Group 'g1'), (New-Lic -Group 'g2' -Plans @() -Sku 'sku-visio'))
        $p = Get-LicensePreservationPlan $l $l $OnHold $false $false
        $p.ProtectedGroupIds | Should -Contain 'g1'
        $p.ProtectedGroupIds | Should -Not -Contain 'g2'
    }
}
