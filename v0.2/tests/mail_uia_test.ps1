# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
. "$PSScriptRoot\lib_synthetic_test.ps1"
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Import-TestFunctions "$v2\lib_邮件读.ps1" @('Read-MailUia') @{'[Windows.Automation.AutomationElement]::FromHandle($h)'='$script:TestRoot'}
$ct=[Windows.Automation.ControlType]
$nodes=@((New-TestNode 'Unread sample message 1' $ct::ListItem),(New-TestNode 'Read sample message 2' $ct::DataItem),(New-TestNode 'Unread sample message 3' $ct::ListItem),(New-TestNode 'x' $ct::ListItem),(New-TestNode 'control' $ct::Button),(New-TestNode '' $ct::Document "line1`nline2`nline3"))
$script:TestRoot=New-TestRoot $nodes
$r=Read-MailUia ([IntPtr]1)
Check 'synthetic UIA list yields 3 mail rows and excludes controls' (@($r.rows).Count -eq 3)
Check 'synthetic UIA unread count is 2' (@($r.rows|Where-Object unread).Count -eq 2)
Check 'synthetic body contains 3 lines' (@($r.body).Count -eq 3)
$limited=Read-MailUia ([IntPtr]1) 1
Check 'row cap is enforced' (@($limited.rows).Count -eq 1)
$script:TestRoot=New-TestRoot @((New-TestNode '' $ct::Document ((1..65|ForEach-Object{"line$_"}) -join "`n")))
Check 'body cap is 40 lines' (@((Read-MailUia ([IntPtr]1)).body).Count -eq 40)
Done-Test
