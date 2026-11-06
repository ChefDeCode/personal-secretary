# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode

function Invoke-TestServerProbe([string]$path){
 Add-Type -AssemblyName System.Net.Http
 $handler=New-Object Net.Http.HttpClientHandler;$handler.AllowAutoRedirect=$false
 $client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(12)
 try{$req=New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get),('https://secretary.demandatlas.online'+$path)
  $resp=$client.SendAsync($req,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult();$status=[int]$resp.StatusCode
  if($status -eq 530){'[SERVER530] status=530';exit 53}
  if($status -ge 200 -and $status -lt 300){"[PASS] read-only endpoint status=$status";exit 0}   # 只有 2xx 算通过；401 / 404 / 5xx 都是失败
  "[FAIL] read-only endpoint status=$status";exit 1
 }catch{$kind=$_.Exception.GetType().Name; if($_.Exception.InnerException){$kind=$_.Exception.InnerException.GetType().Name}; '[ENVIRONMENT] transport=' + $kind + '; no HTTP 530 observed';exit 54}finally{if($resp){$resp.Dispose()};$client.Dispose();$handler.Dispose()}
}
