# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# 聊天双日志：同一chat路径互斥，先持久化加密事务，再补齐两个append。
# 归档和原文从不重写；只有事务状态采用同目录临时文件+原子替换。
function Get-ChatStorageMutexName {
  $path=[IO.Path]::GetFullPath($script:ChatFile).ToLowerInvariant();$sha=[Security.Cryptography.SHA256]::Create()
  try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path)))).Replace('-','')}finally{$sha.Dispose()}
  'Local\SecretaryChat-'+$hash
}
function Enter-ChatStorage {
  $mutex=New-Object Threading.Mutex($false,(Get-ChatStorageMutexName));$held=$false
  try{try{$held=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw 'chat_storage_busy'};$mutex}
  catch{$mutex.Dispose();throw}
}
function Exit-ChatStorage($mutex){if($mutex){try{$mutex.ReleaseMutex()}finally{$mutex.Dispose()}}}
function Write-ChatStorageAtomic([string]$Path,[string]$Text){
  $tmp=$Path+'.'+[guid]::NewGuid().ToString('n')+'.tmp';$bytes=[Text.Encoding]::UTF8.GetBytes($Text)
  try{$fs=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$fs.Write($bytes,0,$bytes.Length);$fs.Flush($true)}finally{$fs.Dispose()}
    if([IO.File]::Exists($Path)){[IO.File]::Replace($tmp,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($tmp,$Path)}
  }finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
}
function Initialize-ChatArchiveLocked {
  if(-not [IO.File]::Exists($script:ChatArchive) -and [IO.File]::Exists($script:ChatFile)){
    $tmp=$script:ChatArchive+'.'+[guid]::NewGuid().ToString('n')+'.tmp'
    try{[IO.File]::Copy($script:ChatFile,$tmp);[IO.File]::Move($tmp,$script:ChatArchive)}finally{if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}}
  }
}
function Get-ChatStorageAppend([string]$Path,[string]$Line){
  $offset=0L;$prefix=''
  if([IO.File]::Exists($Path)){$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{$offset=$stream.Length;if($offset -gt 0){[void]$stream.Seek(-1,[IO.SeekOrigin]::End);if($stream.ReadByte() -ne 10){$prefix="`r`n"}}}finally{$stream.Dispose()}}
  @{offset=$offset;text=$prefix+$Line+"`r`n"}
}
function Write-ChatStorageAppendAt([string]$Path,[long]$Offset,[string]$Text){
  $expected=[Text.Encoding]::UTF8.GetBytes($Text)
  $stream=[IO.File]::Open($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
  try{
    if($stream.Length -lt $Offset){throw 'chat_journal_offset_conflict'}
    $present=[int][Math]::Min($expected.Length,$stream.Length-$Offset);[void]$stream.Seek($Offset,[IO.SeekOrigin]::Begin)
    $seen=New-Object byte[] $present;$read=0
    while($read -lt $present){$n=$stream.Read($seen,$read,$present-$read);if($n -le 0){throw 'chat_journal_short_read'};$read+=$n}
    for($i=0;$i -lt $present;$i++){if($seen[$i] -ne $expected[$i]){throw 'chat_journal_content_conflict'}}
    if($present -lt $expected.Length){$stream.Write($expected,$present,$expected.Length-$present);$stream.Flush($true)}
  }finally{$stream.Dispose()}
}
function Repair-ChatStorageLocked {
  $pending=$script:ChatFile+'.pending'
  if(-not [IO.File]::Exists($pending)){return}
  $txn=(Unprotect ([IO.File]::ReadAllText($pending)))|ConvertFrom-Json
  if(-not $txn -or $txn.schema -ne 1){throw 'chat_pending_unreadable'}
  if($txn.phase -eq 'complete'){return}
  if($txn.phase -ne 'pending'){throw 'chat_pending_invalid_phase'}
  Write-ChatStorageAppendAt $script:ChatArchive ([long]$txn.archive.offset) ([string]$txn.archive.text)
  Write-ChatStorageAppendAt $script:ChatFile ([long]$txn.chat.offset) ([string]$txn.chat.text)
  $txn.phase='complete';Write-ChatStorageAtomic $pending (Protect ($txn|ConvertTo-Json -Depth 6 -Compress))
}
function Get-ChatLineVersion([string]$Line,$Item){
  if($Item._chat_version){return [string]$Item._chat_version}
  $sha=[Security.Cryptography.SHA256]::Create()
  try{'legacy-'+([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Line)))).Replace('-','')}finally{$sha.Dispose()}
}
function Normalize-ChatStorageItem($Item){
  if($Item.card){foreach($key in 'status','result','failed','cancelled','actionId','text','said','itemId'){
    if(-not ($Item.card.PSObject.Properties.Name -contains $key)){$Item.card|Add-Member -NotePropertyName $key -NotePropertyValue $(if($key -eq 'result'){@()}else{$null})}
  }}
  $Item
}
function Read-ChatStorageObjectsLocked([string]$Path){
  if(-not [IO.File]::Exists($Path)){return}
  foreach($line in [IO.File]::ReadLines($Path)){
    if(-not $line){continue};$item=$null
    try{$item=(Unprotect $line)|ConvertFrom-Json}catch{continue}
    if($item -and $item.id){$item|Add-Member -NotePropertyName _chat_version -NotePropertyValue (Get-ChatLineVersion $line $item) -Force;Normalize-ChatStorageItem $item}
  }
}
function Read-ChatStorage([switch]$Archive){
  $lease=Enter-ChatStorage
  try{Initialize-ChatArchiveLocked;Repair-ChatStorageLocked;$path=if($Archive){$script:ChatArchive}else{$script:ChatFile};@(Read-ChatStorageObjectsLocked $path)}
  finally{Exit-ChatStorage $lease}
}
function ConvertTo-ChatStorageValue($Value){
  if($null -eq $Value){return $null}
  # PS 5.1 pipeline wrappers can match PSCustomObject even for strings.
  # Preserve scalar base values before enumerating adapted object properties.
  $scalar=$Value.PSObject.BaseObject
  if($scalar -is [string] -or $scalar -is [ValueType]){return $scalar}
  if($Value -is [Collections.IDictionary]){$map=@{};foreach($key in $Value.Keys){$map[[string]$key]=ConvertTo-ChatStorageValue $Value[$key]};return $map}
  if($Value -is [pscustomobject]){$map=@{};foreach($property in $Value.PSObject.Properties){$map[$property.Name]=ConvertTo-ChatStorageValue $property.Value};return $map}
  if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){return ,@($Value|ForEach-Object {ConvertTo-ChatStorageValue $_})}
  $Value
}
function Test-ChatStorageValueEqual($A,$B){
  if($null -eq $A -or $null -eq $B){return ($null -eq $A -and $null -eq $B)}
  if($A -is [Collections.IDictionary] -and $B -is [Collections.IDictionary]){
    if($A.Count -ne $B.Count){return $false};foreach($key in $A.Keys){if(-not $B.Contains($key) -or -not (Test-ChatStorageValueEqual $A[$key] $B[$key])){return $false}};return $true
  }
  if(($A -is [Collections.IDictionary]) -or ($B -is [Collections.IDictionary])){return $false}
  if($A -is [Collections.IEnumerable] -and $A -isnot [string]){
    if($B -isnot [Collections.IEnumerable] -or $B -is [string]){return $false};$aa=@($A);$bb=@($B);if($aa.Count -ne $bb.Count){return $false}
    for($i=0;$i -lt $aa.Count;$i++){if(-not (Test-ChatStorageValueEqual $aa[$i] $bb[$i])){return $false}};return $true
  }
  ($A -ceq $B)
}
function Merge-ChatStorageValue($Base,$Proposed,$Latest){
  $merged=ConvertTo-ChatStorageValue $Latest;if($merged -isnot [Collections.IDictionary]){$merged=@{}}
  foreach($key in $Proposed.Keys){
    if($key -eq '_chat_version'){continue}
    if($Base -is [Collections.IDictionary] -and $Base.Contains($key) -and (Test-ChatStorageValueEqual $Proposed[$key] $Base[$key])){continue}
    if($Base -is [Collections.IDictionary] -and $Base[$key] -is [Collections.IDictionary] -and $Proposed[$key] -is [Collections.IDictionary]){$merged[$key]=Merge-ChatStorageValue $Base[$key] $Proposed[$key] $merged[$key]}
    else{$merged[$key]=ConvertTo-ChatStorageValue $Proposed[$key]}
  }
  if($Base -is [Collections.IDictionary]){foreach($key in $Base.Keys){if($key -ne '_chat_version' -and -not $Proposed.Contains($key) -and (Test-ChatStorageValueEqual $merged[$key] $Base[$key])){$merged.Remove($key)}}}
  $merged
}
function Sync-ChatStorageValue($Target,$Values){
  # Keep nested card identity: callers may retain $card while updating its parent item.
  foreach($key in $Values.Keys){
    $exists=if($Target -is [Collections.IDictionary]){$Target.Contains($key)}else{$null -ne $Target.PSObject.Properties[$key]}
    $current=if($exists){if($Target -is [Collections.IDictionary]){$Target[$key]}else{$Target.PSObject.Properties[$key].Value}}else{$null}
    if($Values[$key] -is [Collections.IDictionary] -and ($current -is [Collections.IDictionary] -or $current -is [pscustomobject])){Sync-ChatStorageValue $current $Values[$key]}
    elseif($Target -is [Collections.IDictionary]){$Target[$key]=$Values[$key]}
    else{$Target|Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key] -Force}
  }
  $keys=if($Target -is [Collections.IDictionary]){@($Target.Keys)}else{@($Target.PSObject.Properties.Name)}
  foreach($key in $keys){if(-not $Values.Contains($key)){if($Target -is [Collections.IDictionary]){$Target.Remove($key)}else{$Target.PSObject.Properties.Remove($key)}}}
}
function Save-ChatStorageItem($Item,[switch]$Update){
  $lease=Enter-ChatStorage
  try{
    Initialize-ChatArchiveLocked;Repair-ChatStorageLocked
    $proposed=ConvertTo-ChatStorageValue $Item
    if(-not $proposed.id){throw 'chat_item_missing_id'}
    $merged=$proposed
    if($Update){
      $versions=@(Read-ChatStorageObjectsLocked $script:ChatFile|Where-Object {[string]$_.id -eq [string]$proposed.id})
      $latest=$versions|Select-Object -Last 1
      $base=$versions|Where-Object {[string]$_._chat_version -eq [string]$proposed._chat_version}|Select-Object -Last 1
      if($latest -and $base){$merged=Merge-ChatStorageValue (ConvertTo-ChatStorageValue $base) $proposed (ConvertTo-ChatStorageValue $latest)}
      elseif($latest -and $proposed._chat_version){throw 'chat_base_revision_missing'}
    }
    $merged._chat_version=[guid]::NewGuid().ToString('n')
    if($merged.Contains('steps')){$merged.steps=@($merged.steps|Where-Object {$null -ne $_})}
    $line=Protect (ConvertTo-Json -InputObject $merged -Depth 30 -Compress)
    $txn=@{schema=1;phase='pending';archive=(Get-ChatStorageAppend $script:ChatArchive $line);chat=(Get-ChatStorageAppend $script:ChatFile $line)}
    Write-ChatStorageAtomic ($script:ChatFile+'.pending') (Protect ($txn|ConvertTo-Json -Depth 6 -Compress))
    Repair-ChatStorageLocked
    Sync-ChatStorageValue $Item $merged
  }finally{Exit-ChatStorage $lease}
}