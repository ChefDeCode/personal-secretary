# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
. "$PSScriptRoot\lib_synthetic_test.ps1"
Import-TestFunctions "$productRoot\12_值守.ps1" @('Watch-Mail')
$root=Join-Path $env:TEMP ('secretary_mail_'+[guid]::NewGuid().ToString('n')); [void][IO.Directory]::CreateDirectory($root)
function Set-TestCfg($on){[IO.File]::WriteAllText("$root\config.json",(@{features=@{watch_outlook=$on}}|ConvertTo-Json))}
function Get-MailWindow { @{h=[IntPtr]1;proc='synthetic'} }
function Read-MailUia { @{rows=@(@{text='sample1';unread=$true},@{text='sample2';unread=$false});body=@('body1','body2')} }
function Invoke-GhostRead($h,$read){if($script:Blocked){return @{ok=$false}};@{ok=$true;value=(& $read)}}
function Save-Messages($c,$m,$b,$app){$script:Saved+=@($m).Count;$script:Source=$app}
$stats=@{错误=0};$script:Saved=0;$script:MailSig='';$script:Blocked=$false
try {
 Set-TestCfg $false; $script:MailLast=[datetime]::MinValue;Watch-Mail; Check 'disabled source does not read' ($script:Saved -eq 0)
 Set-TestCfg $true; $script:MailLast=[datetime]::MinValue;Watch-Mail;Check '4 synthetic lines enter common storage' ($script:Saved -eq 4 -and $script:Source -eq 'Outlook')
 Check 'mail counts survive collection' ($stats.邮件行 -eq 2 -and $stats.邮件未读 -eq 1)
 $script:MailLast=[datetime]::MinValue;Watch-Mail;Check 'unchanged snapshot is not stored twice' ($script:Saved -eq 4)
 $script:Blocked=$true;$script:MailLast=[datetime]::MinValue;$script:MailSig='';Watch-Mail;Check 'user-active or locked reader yields no storage' ($script:Saved -eq 4)
 Check 'no errors' ($stats.错误 -eq 0)
}finally{if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}}
Done-Test
