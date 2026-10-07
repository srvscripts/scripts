# Changelog: Microsoft 365 User Offboarding PowerShell Script (with -WhatIf)

File: `Invoke-M365Offboarding.ps1`. Page: <https://srvscripts.com/scripts/m365-user-offboarding/>

Newest first. Each version is tagged `m365-user-offboarding/vX.Y.Z` in this repository.

Tested on: 1.1.0 licence decisions tested offline with 28 synthetic cases (group-only and mixed licences, >50 GB, holds, archive, failed/declined conversion, unknown size, -WhatIf and plan-only make no changes); apply mode not yet re-run against a sandbox tenant, so start with the plan and -WhatIf; Syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25 on 6 Oct 2026; not yet run against a live tenant/server.

## 1.1.0

Before any group or licence change the script now decides whether the mailbox still needs its Exchange licence (not confirmed as shared, over 50 GB, any hold, archive, or any fact that cannot be read) and then keeps the groups that assign that licence as well as direct licences. -SkipLicenseRemoval also keeps licence-assigning groups; -ForceLicenseRemoval no longer overrides size or hold checks. Found in an external review (PROD7-04).

## 1.0.0

First release.
