# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 ChefDeCode
# In-memory transport only. Production request builders, parsers, signatures and tool routing still run.
Add-Type -AssemblyName System.Net.Http,System.Web.Extensions,System.Web
if(-not ('SecretaryFixtureHttp' -as [type])){Add-Type -ReferencedAssemblies System.Net.Http,System.Web.Extensions,System.Web @'
using System;using System.Net;using System.Net.Http;using System.Threading;using System.Threading.Tasks;using System.Web;using System.Web.Script.Serialization;using System.Collections.Generic;using System.Text;using System.Text.RegularExpressions;
public sealed class SecretaryFixtureHttp:HttpMessageHandler{
 public readonly JavaScriptSerializer J=new JavaScriptSerializer{MaxJsonLength=int.MaxValue};
 public Dictionary<string,object> Fixture,Release,LastAi;public bool Approved,SignedIn;public string Ent="normal",Ai="ok",Upd="none",Mode="account";
 public Dictionary<string,int> Hits=new Dictionary<string,int>();
 public SecretaryFixtureHttp(string fx,string release){Fixture=J.Deserialize<Dictionary<string,object>>(fx);Release=J.Deserialize<Dictionary<string,object>>(release);}
 Dictionary<string,object> D(object o){return (Dictionary<string,object>)o;}
 object F(string k){return D(Fixture["http"])[k];}
 HttpResponseMessage Text(int code,string body,string type="application/json"){return new HttpResponseMessage((HttpStatusCode)code){Content=new StringContent(body,Encoding.UTF8,type)};}
 HttpResponseMessage Json(int code,object obj){return Text(code,J.Serialize(obj));}
 HttpResponseMessage Replay(object obj,string origin){var d=D(obj);return Text(Convert.ToInt32(d["status"]),J.Serialize(d["json"]).Replace("http://127.0.0.1:8810",origin));}
 HttpResponseMessage Error(int code,string id){return Json(code,new{error=new{code=id,message=id,retryable=false}});}
 public HttpResponseMessage Respond(HttpRequestMessage req){
  var uri=req.RequestUri;string p=uri.AbsolutePath,m=req.Method.Method,origin=uri.GetLeftPart(UriPartial.Authority);var q=HttpUtility.ParseQueryString(uri.Query);
  string body=req.Content==null?"":req.Content.ReadAsStringAsync().GetAwaiter().GetResult();string key=m+" "+p;if(!Hits.ContainsKey(key))Hits[key]=0;Hits[key]++;
  if(uri.Port==1||uri.Port==9)return Error(503,"unreachable");
  if(Mode=="openai"){
   if(req.Headers.Authorization==null||req.Headers.Authorization.Parameter!="sk-test-mock-key-0123456789")return Error(401,"invalid_api_key");
   if(p.EndsWith("/models"))return Json(200,new{data=new[]{new{id="mock-model-a"},new{id="mock-model-b"}}});
   if(p.EndsWith("/chat/completions")){
    object msg=body.Contains("tool_call_id")?(object)new{role="assistant",content="ready"}:new{role="assistant",content=(string)null,tool_calls=new[]{new{id="c1",type="function",function=new{name="propose_send",arguments="{\"as_said\":\"文件传输助手\",\"text\":\"【秘书测试】synthetic\"}"}}}};
    return Json(200,new{model="mock-model-a",choices=new[]{new{message=msg,finish_reason=body.Contains("tool_call_id")?"stop":"tool_calls"}},usage=new{prompt_tokens=3,completion_tokens=2}});
   }return Error(404,"not_found");
  }
  bool auth=req.Headers.Authorization!=null&&req.Headers.Authorization.Parameter=="mock-token-not-secret"&&SignedIn;
  if(p=="/__approve"){Approved=true;return Json(200,new{ok=true});}
  if(p=="/__mode"){Ent=q["ent"]??Ent;Ai=q["ai"]??Ai;Upd=q["upd"]??Upd;return Json(200,new{ent=Ent,ai=Ai});}
  if(p=="/__lastai")return Json(200,LastAi??new Dictionary<string,object>());
  if(p=="/__hits")return Json(200,new{hits=Hits,signedIn=SignedIn});
  if(p=="/healthz")return Replay(F("healthz"),origin);
  if(p=="/v1/meta")return Replay(F("meta"),origin);
  if(p=="/v1/plans")return Replay(F("plans"),origin);
  if(p=="/v1/device/code"){Approved=false;return Replay(F("device_code"),origin);}
  if(p=="/v1/device/token"){
   if(!Approved)return Replay(F("device_token_pending"),origin);SignedIn=true;var t=D(J.DeserializeObject(J.Serialize(F("device_token_ok"))));D(t["json"])["access_token"]="mock-token-not-secret";return Replay(t,origin);
  }
  if(p=="/v1/client/latest"){string k=Upd=="update"?"latest_update":Upd=="required"?"latest_required":Upd=="uptodate"?"latest_up_to_date":"latest_none";return Replay(D(Release["http"])[k],origin);}
  var rel=Regex.Match(p,@"^/v1/client/releases/([^/]+)/([^/]+)/package$");
  if(rel.Success){var all=D(Release["packages"]);string id=Uri.UnescapeDataString(rel.Groups[2].Value);if(!all.ContainsKey(id))return Replay(D(Release["http"])["package_withdrawn_404"],origin);var pk=D(all[id]);var response=new HttpResponseMessage(HttpStatusCode.OK);response.Content=new ByteArrayContent(Convert.FromBase64String((string)pk["zip_b64"]));return response;}
  if(p=="/v1/store/permissions")return Replay(F("store_permissions"),origin);
  if(!auth)return Replay(F("no_token"),origin);
  if(p=="/v1/me")return Replay(F("me"),origin);
  if(p=="/v1/entitlements")return Replay(F(Ent=="trial"?"entitlements_trial":Ent=="exhausted"?"entitlements_daily_exhausted":"entitlements"),origin);
  if(p.StartsWith("/v1/usage"))return Replay(F("usage"),origin);
  if(p=="/v1/devices/self"){SignedIn=false;return Replay(F("logout_self"),origin);}
  if(p=="/v1/billing/checkout")return Replay(F("checkout"),origin);
  if(p=="/v1/store/plugins")return Replay(F("catalog"),origin);
  if(p=="/v1/store/updates")return Replay(F("updates_up_to_date"),origin);
  if(p=="/v1/store/events"||p.EndsWith("/reports"))return Json(200,new{ok=true});
  var pack=Regex.Match(p,@"^/v1/store/plugins/([^/]+)/versions/([^/]+)/(package|signature)$");
  if(pack.Success){string id=Uri.UnescapeDataString(pack.Groups[1].Value)+"-"+Uri.UnescapeDataString(pack.Groups[2].Value);var all=D(Fixture["packages"]);if(!all.ContainsKey(id))return Replay(F("package_withdrawn_404"),origin);var pk=D(all[id]);if(pack.Groups[3].Value=="signature")return Json(200,pk["signature"]);var response=new HttpResponseMessage(HttpStatusCode.OK);response.Content=new ByteArrayContent(Convert.FromBase64String((string)pk["zip_b64"]));response.Headers.Add("x-package-sha256",(string)D(D(pk["signature"])["statement"])["sha256"]);return response;}
  if(p.StartsWith("/v1/store/plugins/"))return Replay(F("detail"),origin);
  if(p=="/v1/ai/messages"){
   LastAi=J.Deserialize<Dictionary<string,object>>(body);
   if(Ai=="quota_daily")return Replay(F("ai_quota_daily"),origin);if(Ai=="quota_lifetime")return Replay(F("ai_quota_lifetime"),origin);if(Ai=="bad_model")return Replay(F("ai_bad_model"),origin);
   string sse=(string)Fixture["sse_ok"];
   if(Ai=="tool"&&!body.Contains("tool_result")){var done=new{stop_reason="tool_use",model="claude-sonnet-5-5",content=new[]{new{type="tool_use",id="toolu_mock1",name="get_today",input=new object()}},usage=new{input_tokens=50,output_tokens=10}};sse="event: start\ndata: {\"model\":\"claude-sonnet-5-5\"}\n\nevent: done\ndata: "+J.Serialize(done)+"\n\n";}
   return Text(200,sse,"text/event-stream");
  }
  return Error(404,"not_found");
 }
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancel){return Task.FromResult(Respond(request));}
}
'@}
function Set-TestHttpTransport([string]$mode='account'){
 $script:TestTransport=New-Object SecretaryFixtureHttp ([IO.File]::ReadAllText("$PSScriptRoot\fixtures\server-0.2.0.json")),([IO.File]::ReadAllText("$PSScriptRoot\fixtures\client-release-0.3.0.json"))
 $script:TestTransport.Mode=$mode
 $script:AcctQuick=New-Object Net.Http.HttpClient($script:TestTransport)
 $script:AcctHttp=New-Object Net.Http.HttpClient($script:TestTransport)
 $script:AiHttp=$script:AcctHttp
}
function Invoke-TestHttp([string]$url,[string]$method='GET'){
 $req=New-Object Net.Http.HttpRequestMessage ([Net.Http.HttpMethod]::new($method)), $url
 $resp=$script:TestTransport.Respond($req)
 [pscustomobject]@{Content=$resp.Content.ReadAsStringAsync().Result;StatusCode=[int]$resp.StatusCode}
}
