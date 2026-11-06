# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
. "$PSScriptRoot\lib_synthetic_test.ps1"
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Import-TestFunctions "$v2\lib_网页读.ps1" @('ConvertTo-SiteHost','Test-SiteAllowed','Get-EdgeUrl','Read-EdgeUia') @{'[Windows.Automation.AutomationElement]::FromHandle($h)'='$script:TestRoot'}
$ct=[Windows.Automation.ControlType]
$script:TestRoot=New-TestRoot @((New-TestNode '' $ct::Edit 'https://work.example.com/tasks'),(New-TestNode '' $ct::Document "a`nb`nc"))
Check 'subdomain allowed; look-alike domain refused' ((Test-SiteAllowed 'https://work.example.com/x' @('example.com')) -and -not (Test-SiteAllowed 'https://badexample.com' @('example.com')) -and -not (Test-SiteAllowed 'https://example.com.evil.io' @('example.com')))
$r=Read-EdgeUia ([IntPtr]1) @('example.com')
Check 'allowed synthetic page has 3 lines' ($r.allowed -and @($r.lines).Count -eq 3)
$script:TestRoot.Reads=0; $r=Read-EdgeUia ([IntPtr]1) @('other.org')
Check 'unlisted site reads address only, never document body' (-not $r.allowed -and @($r.lines).Count -eq 0 -and $script:TestRoot.Reads -eq 1)
$r=Read-EdgeUia ([IntPtr]1) @()
Check 'empty allowlist returns no body' (-not $r.allowed -and @($r.lines).Count -eq 0)
Done-Test
