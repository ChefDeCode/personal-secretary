// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 ChefDeCode
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const v2 = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const baseline = process.argv.includes('--baseline');
let passed = 0, failed = 0;
function check(name, value) { value ? passed++ : failed++; console.log('[' + (value ? 'PASS' : 'FAIL') + '] ' + name); }
function surface(file) {
  const events = {}, messages = [], rafs = new Map(), timers = new Map(), elements = new Map();
  let id = 0, draws = 0, now = 0;
  function element(key) {
    if (elements.has(key)) return elements.get(key);
    const attrs = {}, classes = new Set();
    const el = { style: {}, dataset: {}, innerHTML: '', textContent: '', value: '', hidden: false, children: [], offsetWidth: 300, offsetTop: 0,
      scrollHeight: 600, scrollTop: 0, clientHeight: 600, scrollWidth: 300, clientWidth: 300, tagName: 'DIV',
      classList: { add: (...xs) => xs.forEach(x => classes.add(x)), remove: (...xs) => xs.forEach(x => classes.delete(x)), contains: x => classes.has(x), toggle: (x, on) => { if (on === undefined) on = !classes.has(x); on ? classes.add(x) : classes.delete(x); } },
      setAttribute: (k,v) => { attrs[k] = v; if (key === '#wp' && k === 'd') draws++; }, getAttribute: k => attrs[k], removeAttribute: k => delete attrs[k],
      addEventListener: () => {}, focus: () => {}, remove: () => {}, prepend: () => {}, appendChild: c => el.children.push(c), insertAdjacentHTML: () => {},
      querySelector: s => element(key + ' ' + s), querySelectorAll: () => [], closest: () => null, getBoundingClientRect: () => ({ x:0,y:0,left:0,top:0,right:300,bottom:200,width:300,height:200 }), scrollTo: () => {}, setPointerCapture: () => {} };
    elements.set(key, el); return el;
  }
  const doc = { hidden: false, documentElement: element('html'), body: element('body'), activeElement: null,
    querySelector: element, querySelectorAll: () => [], getElementById: key => element('#' + key), createElement: key => element('new' + (++id) + key),
    addEventListener: (type, fn) => { (events[type] ||= []).push(fn); } };
  const context = { document: doc, console, Map, Set, Date, Math, JSON, Array, String, Object, RegExp, Number,
    innerWidth: 800, innerHeight: 600, screenX: 0, devicePixelRatio: 1,
    performance: { now: () => now }, getComputedStyle: () => ({ getPropertyValue: () => '#777777' }),
    matchMedia: () => ({ matches: false, addEventListener: () => {} }), MutationObserver: class { observe(){} },
    addEventListener: (type, fn) => { (events[type] ||= []).push(fn); },
    setTimeout: (fn, ms) => { const n=++id;timers.set(n,{fn,ms});return n; }, clearTimeout: n => timers.delete(n),
    requestAnimationFrame: fn => {const n=++id;rafs.set(n,fn);return n;}, cancelAnimationFrame: n => rafs.delete(n),
    localStorage: {getItem:()=>null,setItem:()=>{}}, focus:()=>{},
    chrome: { webview: { postMessage: m=>messages.push(m), addEventListener: (type, fn)=>{ (events['host:'+type] ||= []).push(fn); } } } };
  context.window=context; context.globalThis=context;
  vm.createContext(context);
  const html=fs.readFileSync(path.join(v2,'ui',file),'utf8');
  for(const match of html.matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g)) {
    const src=/src="([^"]+)"/.exec(match[1]);
    let code=src?fs.readFileSync(path.join(v2,'ui',src[1]),'utf8'):match[2];
    // Expose existing closure functions only inside this isolated VM, not the product.
    if(!src&&!baseline&&file==='index.html')code=code.replace(/\}\)\(\);\s*$/, 'globalThis.__uiTest={life:life,cardHtml:cardHtml,renderToday:renderToday};})();');
    if(!src&&!baseline&&file==='mini.html')code=code.replace(/\}\)\(\);\s*$/, 'globalThis.__uiTest={life:life,showResult:showResult,S:S};})();');
    vm.runInContext(code,context,{filename:src?src[1]:file});
  }
  return { context,doc,elements,messages,timers,rafs,html,
    hidden(on){doc.hidden=on;(events.visibilitychange||[]).forEach(f=>f());},
    host(d){(events['host:message']||[]).forEach(f=>f({data:d}));},
    frame(){now+=16;const batch=[...rafs.values()];rafs.clear();batch.forEach(f=>f(now));},
    runTimers(ms){const batch=[...timers.entries()].filter(([,t])=>t.ms<=ms);batch.forEach(([n,t])=>{timers.delete(n);t.fn();});},
    draws(){return draws;} };
}
try {
  const edge=surface('edge.html');edge.frame();edge.hidden(true);const before=edge.draws();edge.frame();edge.frame();
  check('hidden edge schedules no frame and performs no drawing',edge.rafs.size===0&&edge.draws()===before);
  if(!baseline){edge.hidden(false);check('visible edge restarts exactly one animation loop',edge.rafs.size===1);edge.frame();check('edge resumes drawing',edge.draws()>before);
    for(let i=0;i<1000;i++)edge.frame();check('settled idle wave stops scheduling animation frames',edge.rafs.size===0);
    edge.host({type:'hover',on:true});check('hover wakes settled wave without polling',edge.rafs.size===1);
    edge.host({type:'state',base:'reading'});for(let i=0;i<1000;i++)edge.frame();check('reading wave preserves continuous animation',edge.rafs.size===1);
  }
  const mini=surface('mini.html');
  mini.host({type:'mini',today:[],wave:{state:'reading',text:''},reminders:[]});
  check('closed mini pauses CSS animations',mini.doc.documentElement.getAttribute('data-page-active')==='false');
  if(!baseline){
    mini.host({type:'vis',open:true});check('open mini resumes animations immediately',mini.doc.documentElement.getAttribute('data-page-active')==='true');
    mini.host({type:'mini',today:[{id:'a',group:'promise',what:'synthetic task',due:'2026-11-07',due_bucket:'soon'}],wave:{state:'idle'},reminders:[]});
    check('mini shows future task in due bucket',mini.elements.get('#body').innerHTML.includes('快到期')&&mini.elements.get('#body').innerHTML.includes('synthetic task'));
    mini.host({type:'mini',today:[{id:'a',group:'promise',what:'synthetic revised',due:'2026-11-08',due_bucket:'soon',reason:'still pending'}],wave:{state:'idle'},reminders:[]});
    check('same ID changed content refreshes visible mini',mini.elements.get('#body').innerHTML.includes('synthetic revised'));
    mini.host({type:'vis',open:false});mini.runTimers(500);check('mini suspends after closing transition',mini.doc.documentElement.getAttribute('data-page-active')==='false');
    const old=mini.elements.get('#body').innerHTML;
    for(let i=0;i<1000;i++)mini.host({type:'mini',today:[{id:'a',group:'promise',what:'hidden '+i,due_bucket:'undated'}],wave:{state:'idle'},reminders:[]});
    check('1000 hidden snapshots cause no DOM refresh',mini.elements.get('#body').innerHTML===old);
    check('1000 hidden snapshots retain one snapshot',mini.context.__uiTest.life.pendingCount()===1);
    mini.host({type:'vis',open:true});check('reopen applies latest hidden snapshot',mini.elements.get('#body').innerHTML.includes('hidden 999'));
    mini.host({type:'vis',open:false});mini.host({type:'vis',open:true,resume:true});mini.runTimers(500);
    check('quick reopen cancels closing suspension',mini.doc.documentElement.getAttribute('data-page-active')==='true');
    mini.context.__uiTest.showResult({id:'test-send',card:{actionState:'unknown',needsVerification:true}});
    check('unknown result renders exactly two choices',(mini.elements.get('#body').innerHTML.match(/data-resolve=/g)||[]).length===2);
    mini.context.__uiTest.S.wait={kind:'send',id:'old-action'};
    const snapshot=[{id:'old-action',role:'ai',card:{status:'closed',actionState:'unknown',needsVerification:true}}].concat(Array.from({length:100},(_,i)=>({id:'later-'+i,role:'ai',text:''})));
    mini.host({type:'chat',chat:{items:snapshot}});
    check('authoritative snapshot finds waiting action beyond last 80 items',mini.context.__uiTest.S.wait.id==='old-action'&&mini.elements.get('#body').innerHTML.includes('结果待核对'));
    mini.host({type:'chat',chat:{items:[{id:'old-action',role:'ai',card:{status:'closed',actionState:'succeeded',result:[{ok:true,text:'verified'}]}}]}});
    check('snapshot resolves current waiting action with latest result',mini.context.__uiTest.S.wait===null&&mini.elements.get('#steps').innerHTML.includes('verified'));
    const main=surface('index.html');main.host({type:'pageVisibility',visible:false});
    main.host({type:'busy',on:true});check('main defers hidden data rendering',main.doc.getElementById('busy').textContent!=='秘书在想…');
    main.host({type:'pageVisibility',visible:true});check('main flushes visible data immediately',main.elements.get('#busy').textContent==='秘书在想…');
    check('main contains all four date groups',['today','soon','overdue','undated'].every(x=>main.html.includes('data-g="'+x+'"')));
    check('main offers exactly the two unknown-result choices',main.html.includes('已经发出了')&&main.html.includes('没发出，重发')&&main.html.includes("type:'resolveSend'"));
    check('mini offers both unknown-result choices',mini.html.includes('已经发出了')&&mini.html.includes('没发出，重发')&&mini.html.includes("type:'resolveSend'"));
    const html=main.context.__uiTest.cardHtml({itemId:'test',kind:'send',status:'closed',actionId:'test',actionState:'unknown',failed:true,result:[{ok:false,text:'uncertain'}]});
    check('unknown result cannot expose ordinary retry',!html.includes('data-sretry')&&(html.match(/data-resolve-send=/g)||[]).length===2);
    const groups=['today','soon','overdue','undated'].map(x=>{const el=main.doc.querySelector('group-'+x);el.dataset.g=x;return el;});
    main.doc.querySelectorAll=sel=>sel==='.grp[data-g]'?groups:[];
    main.context.__uiTest.renderToday(groups.map((g,i)=>({id:'t'+i,group:i===0?'reply':'promise',what:'synthetic '+i,quote:'quote',due_bucket:g.dataset.g,response_state:'acknowledged',reason:'still pending'})));
    check('date groups retain task category and reason',groups.every(g=>g.querySelector('.cards').innerHTML.includes('still pending'))&&groups[1].querySelector('.cards').innerHTML.includes('你答应过'));
    const life=main.context.__uiTest.life;let fired=0;const tid=life.timeout(()=>fired++,500);
    life.setVisible(false);main.runTimers(1000);check('hidden visual timer does not fire',fired===0);
    life.setVisible(true);main.runTimers(1000);check('visible visual timer fires once',fired===1);life.clearTimeout(tid);
    main.host({type:'pageVisibility',visible:false});for(let i=0;i<1000;i++)main.host({type:'item',item:{id:'hidden'+i}});
    check('hidden item cache stays bounded',life.pendingCount()<=128);
    const resumes=main.messages.filter(m=>m.type==='pageResumed').length;main.host({type:'pageVisibility',visible:true});
    check('resume requests authoritative host refresh',main.messages.filter(m=>m.type==='pageResumed').length===resumes+1);
  }
} catch(e) { failed++;console.log('[FAIL] runtime exception '+e.name+' '+e.message); }
console.log('ui_reliability_test: '+passed+' pass, '+failed+' fail');
process.exitCode=failed?1:0;
