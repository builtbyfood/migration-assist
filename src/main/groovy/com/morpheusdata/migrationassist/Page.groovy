package com.morpheusdata.migrationassist

/**
 * Page markup. CSS/JS are triple-single-quoted (no Groovy interpolation) and deliberately use
 * no backslashes or regex literals, same rule as hvm-updater's FleetPage.
 */
class Page {

    static String html(String nonce) {
        String n = nonce ? ' nonce="' + nonce + '"' : ''
        return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
               '<title>Migration Assist</title><style' + n + '>' + CSS + '</style></head><body>' + BODY +
               '<script' + n + '>' + JS + '</script></body></html>'
    }

    static final String CSS = '''
:root{--bg:#f6f7f9;--card:#fff;--fg:#1f2328;--muted:#6b7280;--line:#e5e7eb;--accent:#01a982;--warn:#b45309;--bad:#b91c1c;--ok:#15803d;--info:#2563eb}
@media (prefers-color-scheme:dark){:root{--bg:#141618;--card:#1c1f23;--fg:#e6e8eb;--muted:#9aa2ad;--line:#2b3138}}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 -apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--fg)}
.wrap{max-width:1240px;margin:0 auto;padding:20px}h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:0 0 10px}h3{font-size:14px;margin:14px 0 6px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:16px;margin:0 0 16px}
.muted{color:var(--muted)}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:600;color:var(--muted);font-size:12px;text-transform:uppercase}
button{background:var(--accent);color:#fff;border:0;border-radius:6px;padding:6px 12px;cursor:pointer;font:inherit}button.secondary{background:transparent;color:var(--fg);border:1px solid var(--line)}
button:disabled{opacity:.5;cursor:default}a.lnk{color:var(--accent);cursor:pointer;text-decoration:none;font-weight:600}
.pill{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;border:1px solid var(--line);margin-right:4px}
.pill.ok{color:var(--ok);border-color:var(--ok)}.pill.warn{color:var(--warn);border-color:var(--warn)}.pill.bad{color:var(--bad);border-color:var(--bad)}.pill.info{color:var(--info);border-color:var(--info)}
.steps{display:flex;gap:6px;flex-wrap:wrap;margin:6px 0}.step{padding:3px 9px;border-radius:6px;border:1px solid var(--line);font-size:12px}
.step.complete{border-color:var(--ok);color:var(--ok)}.step.running{border-color:var(--accent);background:var(--accent);color:#fff}.step.failed,.step.stalled{border-color:var(--bad);background:var(--bad);color:#fff}
.chk{margin:2px 0;font-size:13px}.chk b{display:inline-block;min-width:44px}.chk.ok b{color:var(--ok)}.chk.warn b{color:var(--warn)}.chk.bad b{color:var(--bad)}.chk.info b{color:var(--info)}
.vm{border:1px solid var(--line);border-radius:8px;padding:12px;margin:10px 0}
pre{background:#0b0e12;color:#d7dde5;padding:10px;border-radius:6px;max-height:420px;overflow:auto;font-size:12px;white-space:pre-wrap}
input[type=text],select{font:inherit;padding:4px 6px;border:1px solid var(--line);border-radius:4px;background:var(--bg);color:var(--fg)}
label{margin-right:12px}.bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin:8px 0}
'''

    static final String BODY = '''
<div class="wrap">
<h1>Migration Assist</h1>
<div class="muted" id="hdr">Loading...</div>
<div class="card"><h2>Migration plans <button class="secondary" id="reload">Reload</button></h2>
  <div id="plans" class="muted">Loading...</div>
  <h3>Credential profile</h3>
  <div class="muted">Tick plans above, then apply a Trust credential. It is saved for each plan's post-migration run, and for <b>pending</b> plans it is also written into the plan's own Windows/Linux credentials. The password is resolved on the appliance and never sent to this page.</div>
  <div class="bar"><select id="credPick" style="min-width:320px"><option value="">Loading credentials...</option></select>
    <input type="text" id="credRef" placeholder="or type an ID, name or secret/... cypher key" style="width:260px">
    <select id="credOs"><option value="windows">Windows</option><option value="linux">Linux</option></select>
    <button id="assign">Apply to selected plans</button> <span id="assignMsg" class="muted"></span></div>
</div>
<div class="card" id="detailCard" style="display:none"><h2 id="dTitle">Plan</h2>
  <div class="bar"><button class="secondary" id="dRefresh">Refresh</button><button id="dSnap">Take NIC snapshot</button><button id="dPorts">Check connectivity + logins</button>
    <span id="dMsg" class="muted"></span></div>
  <div id="detail"></div></div>
<div class="card" id="logCard" style="display:none"><h2>Appliance log for this plan</h2>
  <div class="bar"><select id="logLevel"><option value="WARN|ERROR">WARN + ERROR</option><option value="ERROR">ERROR</option><option value="INFO|WARN|ERROR">All levels</option></select>
    <label><input type="checkbox" id="logAll"> all lines in the window (not just this plan's VMs/IPs)</label>
    <button class="secondary" id="logLoad">Load</button> <span id="logMsg" class="muted"></span></div>
  <pre id="log">-</pre></div>
</div>
'''

    static final String JS = '''
(function(){
var base='/plugin/migrationAssist/api', S={plans:[],cur:null,sel:{},timer:null};
function q(u,d){if(d){var qs=Object.keys(d).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(d[k])}).join('&');if(qs)u+=(u.indexOf('?')<0?'?':'&')+qs}
  return fetch(base+u,{credentials:'same-origin',cache:'no-store'}).then(function(r){if(!r.ok)throw new Error('HTTP '+r.status);return r.json()}).catch(function(e){return {error:e.message}})}
function esc(s){return String(s==null?'':s).split('&').join('&amp;').split('<').join('&lt;').split('>').join('&gt;').split('"').join('&quot;')}
function el(id){return document.getElementById(id)}
function pill(t,c){return '<span class="pill '+(c||'')+'">'+esc(t)+'</span>'}
function stPill(s){var c={pending:'info',running:'warn',completed:'ok',complete:'ok',failed:'bad',scheduled:'info',precheck:'warn'}[s]||'';return pill(s||'?',c)}
function when(t){if(!t)return '<span class="muted">never</span>';var d=new Date(t);return isNaN(d)?esc(t):esc(d.toLocaleString())}

function loadPlans(){q('/plans').then(function(r){
  if(r.error){el('plans').innerHTML='<span style="color:var(--bad)">'+esc(r.error)+'</span>';return}
  S.plans=r.plans||[];S.scriptVersion=r.scriptVersion;var t=r.token||{};
  el('hdr').innerHTML='v'+esc(r.version||'?')+' &middot; API token: '+(t.source?pill(t.source,t.source=='setting'?'warn':'ok'):pill('none','bad'))+(t.serviceCredential?' <span class="muted">service credential #'+esc(t.serviceCredential)+(t.serviceUser?' (user '+esc(t.serviceUser)+')':'')+'</span>':'')+(t.lastError?' <span style="color:var(--bad)">'+esc(t.lastError)+(t.retryInMinutes!=null?' - not retrying for '+t.retryInMinutes+' min':'')+'</span>':'')+
    ' &middot; snapshot poller last ran '+when(r.lastTick)+(r.lastTickError?' <span style="color:var(--bad)">'+esc(r.lastTickError)+'</span>':'');
  var h='<table><tr><th></th><th>Plan</th><th>Status</th><th>VMs</th><th>Credentials</th><th>NIC snapshot</th></tr>';
  S.plans.forEach(function(p){
    var vs=Object.keys(p.vmStatus||{}).map(function(k){return p.vmStatus[k]+' '+k}).join(', ');
    var cr=(p.windowsUsername?'Windows: '+esc(p.windowsUsername):'')+(p.linuxUsername?(p.windowsUsername?'<br>':'')+'Linux: '+esc(p.linuxUsername):'')||'<span class="muted">none</span>';(p.assignment||[]).forEach(function(a){cr+='<div class="muted">profile: '+esc(a.os)+' #'+esc(a.credentialRef)+' ('+esc(a.username)+')</div>'});
    h+='<tr><td>'+'<input type="checkbox" class="psel" value="'+p.id+'"'+(S.sel[p.id]?' checked':'')+' title="'+(p.status=='pending'?'pending: saved and written into the plan':'saved for the post-migration run only')+'">'+'</td>'+
       '<td><a class="lnk" data-open="'+p.id+'">'+esc(p.name)+'</a><div class="muted">id '+p.id+' &middot; '+esc(p.sourceCloud||'')+' &rarr; '+esc(p.targetCloud||'')+'</div></td>'+
       '<td>'+stPill(p.status)+(p.statusMessage?'<div class="muted">'+esc(p.statusMessage)+'</div>':'')+'</td><td>'+p.vmCount+'<div class="muted">'+esc(vs)+'</div></td>'+
       '<td>'+cr+'</td><td>'+when(p.snapshotAt)+'</td></tr>'});
  el('plans').innerHTML=S.plans.length?h+'</table>':'<span class="muted">No migration plans.</span>';
  Array.prototype.forEach.call(document.querySelectorAll('[data-open]'),function(a){a.onclick=function(){openPlan(+a.getAttribute('data-open'))}});
  Array.prototype.forEach.call(document.querySelectorAll('.psel'),function(c){c.onchange=function(){S.sel[c.value]=c.checked}});
})}

function openPlan(id){S.cur=id;el('detailCard').style.display='';el('logCard').style.display='';el('log').textContent='-';loadPlan();loadLogs()}
function loadPlan(){if(!S.cur)return;q('/plan',{id:S.cur}).then(function(r){
  if(S.timer){clearTimeout(S.timer);S.timer=null}
  if(r.error){el('detail').innerHTML='<span style="color:var(--bad)">'+esc(r.error)+'</span>';return}
  var p=r.plan;el('dTitle').innerHTML=esc(p.name)+' '+stPill(p.status);
  var h='<div class="muted">Guest tools: '+(p.installGuestTools?'install':'skip')+' &middot; prechecks: '+(p.skipPrechecks?'skipped':'on')+
     ' &middot; Windows creds: '+(p.windowsUsername?esc(p.windowsUsername)+(p.windowsPasswordSet?' (password set)':' (no password)'):'none')+
     ' &middot; Linux creds: '+(p.linuxUsername?esc(p.linuxUsername):'none')+' &middot; snapshot '+when(r.snapshotAt)+'</div>';
  h+='<h3>Network mapping</h3><table><tr><th>Source</th><th>Destination</th><th>DHCP</th><th>CIDR / gateway</th><th>VLAN</th></tr>';
  (r.networks||[]).forEach(function(n){h+='<tr><td>'+esc(n.sourceName)+' <span class="muted">#'+n.sourceId+'</span></td><td>'+esc(n.destName||'-')+' <span class="muted">#'+(n.destId||'')+'</span></td><td>'+
     (n.dhcpServer?pill('on','ok'):pill('off','warn'))+'</td><td>'+(n.cidr?esc(n.cidr):'<span class="muted">not set</span>')+(n.gateway?' / '+esc(n.gateway):'')+'</td><td>'+esc(n.vlanId||'')+'</td></tr>'});
  h+='</table><h3>VMs</h3>';
  (r.vms||[]).forEach(function(v){
    h+='<div class="vm"><b>'+esc(v.sourceName)+'</b> <span class="muted">#'+v.sourceId+(v.platform?' &middot; '+esc(v.platform):'')+(v.powerState?' &middot; '+esc(v.powerState):'')+'</span> '+stPill(v.status)+
       (v.destId?' &rarr; '+esc(v.destName)+' <span class="muted">#'+v.destId+'</span>':'')+(v.agent?' '+(v.agent.installed?pill('agent '+(v.agent.version||''),'ok'):pill('no agent','warn')):'')+(v.managed&&v.managed.managed===true?' '+pill('managed','ok'):'')+(v.managed&&v.managed.managed===false?' '+pill('unmanaged','bad'):'')+(v.readyForPostRun?' '+pill('ready for post-migration run','ok'):(v.instanceBusy?' '+pill('instance still provisioning','warn'):''))+(v.stalled?' '+pill('stalled','bad'):'');
    (v.issues||[]).forEach(function(c){h+='<div class="chk '+c.level+'"><b>'+c.level+'</b> '+esc(c.msg)+'</div>'});
    var tid=v.destId||v.sourceId, tname=v.destId?v.destName:v.sourceName;
    var inv=(v.inventory&&v.inventory.products)||[];
    h+='<div class="vm" style="margin:8px 0"><b>Post-migration</b> <span class="muted">Invoke-VMwareToVirtio '+esc(S.scriptVersion||'')+' on '+esc(tname)+'</span>';
    h+='<div class="bar"><button class="secondary" data-inv="'+v.sourceId+'">Scan VMware/Broadcom software</button>'+(v.inventory?'<span class="muted">scanned '+when(v.inventory.at)+'</span>':'')+'</div>';
    if(inv.length){h+='<table><tr><th></th><th>Product</th><th>Version</th><th>Publisher</th><th>Class</th></tr>';
      inv.forEach(function(p){h+='<tr><td>'+(p.Class=='other'?'<input type="checkbox" class="prodsel" data-src="'+v.sourceId+'" value="'+esc(p.Code)+'">':'')+'</td><td>'+esc(p.Name)+'</td><td>'+esc(p.Version)+'</td><td>'+esc(p.Publisher)+'</td><td>'+
        (p.Class=='tools'?pill('VMware Tools','info'):p.Class=='protected'?pill('protected - report only','bad'):pill('other','warn'))+'</td></tr>'});h+='</table>'}
    else if(v.inventory){h+='<div class="muted">No VMware/Broadcom/Omnissa software besides what the scan reported.</div>'}
    h+='<div class="bar"><select id="scope'+v.sourceId+'"><option value="ToolsOnly">Remove VMware Tools only</option><option value="Selected">VMware Tools + ticked products</option><option value="AllVMware">Everything VMware-published (KB 315629 sweep)</option></select>'+
       '<button data-postrun="'+v.sourceId+'"'+(v.readyForPostRun?'':' disabled title="not ready: migration or instance provisioning still running"')+'>Run post-migration script</button>'+
       (v.postRun&&v.postRun.result?' <span class="muted">last run '+when(v.postRun.at)+': </span>'+pill(v.postRun.result.status,v.postRun.result.status=='ok'?'ok':'warn'):'')+'</div>';
    h+='<div id="jobLog'+v.sourceId+'"></div></div>';
    h+='<div class="bar"><button class="secondary" data-agent="'+tid+'" data-name="'+esc(tname)+'">Install agent (remote run)</button>'+
       '<a class="lnk" href="/infrastructure/servers/'+tid+'/download-agent-script">Download agent script</a>'+
       ' <span class="muted">target: '+esc(tname)+' #'+tid+'</span></div><div id="agentLog'+tid+'"></div>';
    h+='<div class="bar"><button class="secondary" data-fixvm="'+v.sourceId+'">Apply profile to VM login</button>'+(v.recordUser?' <span class="muted">VM record login: '+esc(v.recordUser)+'</span>':'')+'</div>';
    if(v.instance&&v.instance.processes&&v.instance.processes.length){h+='<div class="steps"><span class="muted" style="align-self:center">instance #'+v.instance.instanceId+':</span>';
      v.instance.processes.slice().reverse().forEach(function(pr){var cur=(pr.status=='running'||pr.status=='queued'||pr.status=='pending');
        var sub=cur?(pr.events||[]).filter(function(e){return e.status=='running'||e.status=='queued'}).map(function(e){return e.name}).join(', '):'';
        h+='<span class="step '+esc(cur?'running':pr.status)+'">'+esc(pr.name||pr.displayName)+(sub?': '+esc(sub):'')+'</span>'});h+='</div>'}
    if(v.phases&&v.phases.length){h+='<div class="steps">';v.phases.forEach(function(ph){var cls=ph.stalled?'stalled':ph.status;
      var tip=(ph.lastUpdated?'last update '+ph.lastUpdated:'')+(ph.idleMinutes!=null?' ('+ph.idleMinutes+' min ago)':'')+(ph.error?' | '+ph.error:'');
      h+='<span class="step '+esc(cls)+'" title="'+esc(tip)+'">'+esc(ph.name)+(ph.status=='running'?' '+Math.round(ph.percent||0)+'%':'')+'</span>'});h+='</div>';
      v.phases.filter(function(ph){return ph.error}).forEach(function(ph){h+='<div class="chk bad"><b>error</b> '+esc(ph.name)+': '+esc(ph.error)+'</div>'})}
    h+='<div class="muted" id="vc'+v.sourceId+'" data-vcname="'+esc(v.sourceName)+'"></div>';
    h+='<table><tr><th>NIC (MAC)</th><th>IP</th><th>Source network</th><th>Checks</th></tr>';
    (v.nics||[]).forEach(function(n){h+='<tr><td>'+esc(n.name||'')+'<div class="muted">'+esc(n.macAddress)+'</div></td><td>'+(n.ipAddress?esc(n.ipAddress)+(n.ipFrom&&n.ipFrom!='live'?'<div class="muted">from '+esc(n.ipFrom)+'</div>':''):'<span class="muted">none</span>')+'</td>'+
      '<td>'+esc(n.networkName||'')+' <span class="muted">#'+(n.networkId||'')+'</span></td><td>'+(n.checks||[]).map(function(c){return '<div class="chk '+c.level+'"><b>'+c.level+'</b> '+esc(c.msg)+'</div>'}).join('')+'</td></tr>'});
    if(!(v.nics||[]).length)h+='<tr><td colspan="4" class="muted">No snapshot for this VM yet.</td></tr>';
    h+='</table>';
    if(v.ports&&v.ports.results){h+='<div class="muted" style="margin-top:6px">Ports from appliance ('+when(v.ports.checkedAt)+'): '+v.ports.results.map(function(x){return esc(x.ip+':'+x.port)+' '+(x.open?pill('open','ok'):pill('closed','bad'))}).join(' ')+'</div>'}
    h+='</div>'});
  el('detail').innerHTML=h;
  Array.prototype.forEach.call(document.querySelectorAll('[data-agent]'),function(b){b.onclick=function(){
    var sid=b.getAttribute('data-agent');
    if(!confirm('Download the Morpheus agent script for this VM and run it over WinRM with the plan Windows credential profile?'))return;
    b.disabled=true;var out=el('agentLog'+sid);out.innerHTML='<pre>starting...</pre>';
    q('/agentInstall',{id:S.cur,serverId:sid,name:b.getAttribute('data-name')}).then(function(r){
      if(r.error){out.innerHTML='<pre>'+esc(r.error)+'</pre>';b.disabled=false;return}
      (function poll(){q('/agentJob',{job:r.jobId}).then(function(j){
        var nl=String.fromCharCode(10);
        out.innerHTML='<pre>'+esc((j.steps||[]).map(function(x){return x.at.substr(11,8)+'  '+x.msg}).join(nl)+(j.output?nl+nl+j.output:''))+'</pre>';
        if(j.state=='running')setTimeout(poll,4000);else{b.disabled=false;setTimeout(function(){loadPlan()},2000)}})})()})}});
  function runJob(path,args,out,btn){btn.disabled=true;out.innerHTML='<pre>starting...</pre>';
    q(path,args).then(function(r){
      if(r.error){out.innerHTML='<pre>'+esc(r.error)+'</pre>';btn.disabled=false;return}
      (function poll(){q('/agentJob',{job:r.jobId}).then(function(j){
        var nl=String.fromCharCode(10);
        out.innerHTML='<pre>'+esc((j.steps||[]).map(function(x){return x.at.substr(11,8)+'  '+x.msg}).join(nl))+'</pre>';
        if(j.state=='running')setTimeout(poll,5000);else{btn.disabled=false;setTimeout(function(){loadPlan()},1500)}})})()})}
  Array.prototype.forEach.call(document.querySelectorAll('[data-inv]'),function(b){b.onclick=function(){
    var sid=b.getAttribute('data-inv');runJob('/inventory',{id:S.cur,sourceId:sid},el('jobLog'+sid),b)}});
  Array.prototype.forEach.call(document.querySelectorAll('[data-postrun]'),function(b){b.onclick=function(){
    var sid=b.getAttribute('data-postrun'),scope=el('scope'+sid).value;
    var prods=Array.prototype.filter.call(document.querySelectorAll('.prodsel'),function(c){return c.getAttribute('data-src')==sid&&c.checked}).map(function(c){return c.value});
    if(scope=='Selected'&&!prods.length){alert('Tick the products to uninstall, or pick VMware Tools only.');return}
    var msg='Run the post-migration script on the migrated VM now? It installs the full VirtIO set, removes '+(scope=='ToolsOnly'?'VMware Tools':scope=='Selected'?'VMware Tools and '+prods.length+' selected product(s)':'everything VMware-published')+', restores the NIC settings (the VM address changes) and reboots it.';
    if(!confirm(msg))return;
    runJob('/postRun',{id:S.cur,sourceId:sid,scope:scope,products:prods.join(',')},el('jobLog'+sid),b)}});
  Array.prototype.forEach.call(document.querySelectorAll('[data-fixvm]'),function(b){b.onclick=function(){
    if(!confirm('Write the plan credential profile into the VM record login (used by Morpheus for WinRM and VMware Tools)?'))return;
    el('dMsg').textContent='updating VM login...';
    q('/fixVmLogin',{id:S.cur,serverId:b.getAttribute('data-fixvm')}).then(function(r){el('dMsg').textContent=r.error||('VM login set to '+r.username+'. Run the check again in a minute.');loadPlan()})}});
  var busy=(r.vms||[]).some(function(v){return v.instanceBusy});
  if(busy&&p.status=='completed'){S.timer=setTimeout(function(){loadPlan()},20000)}
  if(p.status=='running'||p.status=='precheck'||p.status=='scheduled'){S.timer=setTimeout(function(){loadPlan();loadLogs()},20000);loadVc()}
})}

function loadVc(){q('/vcenter',{id:S.cur}).then(function(r){
  Array.prototype.forEach.call(document.querySelectorAll('[data-vcname]'),function(d){
    var nm=(d.getAttribute('data-vcname')||'').toLowerCase();
    if(r.error){d.innerHTML='vCenter progress: <span style="color:var(--warn)">'+esc(r.error)+'</span>';return}
    var ts=(r.tasks||[]).filter(function(t){return (t.entityName||'').toLowerCase()==nm});
    d.innerHTML=ts.length?ts.map(function(t){return 'vCenter: '+esc(t.name||t.descriptionId)+' '+pill((t.progress!=null?t.progress+'%':t.state),'warn')}).join(' '):'vCenter: no running task for this VM'})})}
function loadLogs(){if(!S.cur)return;el('logMsg').textContent='loading...';
  q('/logs',{id:S.cur,level:el('logLevel').value,all:el('logAll').checked?'true':'false',max:300}).then(function(r){
  if(r.error){el('logMsg').textContent=r.error;return}
  el('logMsg').textContent=(r.rows||[]).length+' of '+r.scanned+' lines from '+new Date(r.since).toLocaleString()+(r.until?' to '+new Date(r.until).toLocaleString():' to now')+(r.terms&&r.terms.length&&!el('logAll').checked?' matching '+r.terms.join(', '):'');
  el('log').textContent=(r.rows||[]).map(function(l){return l.ts+'  '+l.level+'  '+(l.host?'['+l.host+'] ':'')+l.message}).join(String.fromCharCode(10))||'(no matching lines)'})}

function loadCreds(){q('/credentials').then(function(r){var sel=el('credPick');
  if(r.error){sel.innerHTML='<option value="">'+esc('credentials: '+r.error)+'</option>';return}
  var h='<option value="">Pick a Trust credential...</option>';
  (r.credentials||[]).forEach(function(c){h+='<option value="'+c.id+'">'+esc(c.name)+' (#'+c.id+')'+(c.username?' - '+esc(c.username):'')+(c.type?' - '+esc(c.type):'')+'</option>'});
  sel.innerHTML=h})}
el('credPick').onchange=function(){if(el('credPick').value)el('credRef').value=el('credPick').value};
el('reload').onclick=function(){loadPlans();loadCreds()};
el('dRefresh').onclick=function(){loadPlan()};
el('dSnap').onclick=function(){el('dMsg').textContent='snapshotting...';q('/snapshot',{id:S.cur}).then(function(r){el('dMsg').textContent=r.error||((r.errors&&r.errors.length)?'partial: '+r.errors.join('; '):'snapshot saved for '+r.vms+' VM(s)');loadPlan();loadPlans()})};
el('dPorts').onclick=function(){el('dMsg').textContent='checking ports...';q('/ports',{id:S.cur}).then(function(r){el('dMsg').textContent=r.error||'done';loadPlan()})};
el('logLoad').onclick=loadLogs;
el('assign').onclick=function(){var ids=Object.keys(S.sel).filter(function(k){return S.sel[k]});
  el('assignMsg').textContent='applying...';
  q('/assign',{ref:el('credRef').value,os:el('credOs').value,ids:ids.join(',')}).then(function(r){
    if(r.error){el('assignMsg').innerHTML='<span style="color:var(--bad)">'+esc(r.error)+'</span>';return}
    el('assignMsg').textContent=(r.results||[]).map(function(x){return 'plan '+x.planId+': '+(x.ok?(x.note||'ok'):x.error)}).join(' | ')+(r.username?' (user '+r.username+')':'');loadPlans()})};
loadPlans();loadCreds();
})();
'''
}
