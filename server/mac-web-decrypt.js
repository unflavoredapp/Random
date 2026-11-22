// Brand: FastDecrypt · https://fastdecrypt.bot
"use strict";
/**
 * Public web decrypt UI served by mac-https-api on fastdecrypt.bot.
 * IPA handoff uses /d/<token> so files up to WEB_MAX_BYTES (~6 GB) download over HTTPS.
 */

const WEB_MAX_BYTES =
  Math.max(1, Number(process.env.MAC_WEB_MAX_GB || 6) || 6) * 1024 * 1024 * 1024;

function sendHtml(res, { build = "" } = {}) {
  const maxGb = (WEB_MAX_BYTES / (1024 * 1024 * 1024)).toFixed(0);
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<meta name="color-scheme" content="dark"/>
<meta name="theme-color" content="#0a0c12"/>
<title>FastDecrypt</title>
<style>
:root{
  --bg0:#07090f;--bg1:#121826;--ink:#eef2ff;--mut:#9aa6bf;
  --acc:#ff9a1f;--acc2:#ffc46b;--line:rgba(255,255,255,.1);--ok:#3dd68c;--bad:#ff6b6b;
  /* Local-only fonts — Google Fonts blocked/slow in some in-app browsers. */
  --font-display:"Avenir Next Condensed","Avenir Next",ui-rounded,"Segoe UI",system-ui,sans-serif;
  --font-body:"Avenir Next","Segoe UI",system-ui,sans-serif;
}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%}
body{
  font-family:var(--font-body);color:var(--ink);
  background:
    radial-gradient(1200px 700px at 12% -10%,rgba(255,154,31,.22),transparent 55%),
    radial-gradient(900px 600px at 95% 10%,rgba(56,110,255,.14),transparent 50%),
    linear-gradient(165deg,var(--bg0),var(--bg1) 55%,#0b1020);
}
.wrap{max-width:560px;margin:0 auto;padding:clamp(28px,6vw,56px) 20px 64px}
.brand{
  font-family:var(--font-display);font-weight:800;font-size:clamp(2.4rem,9vw,3.4rem);
  letter-spacing:-.04em;line-height:.95;margin:0 0 12px;
  background:linear-gradient(120deg,#fff 20%,var(--acc2) 70%,var(--acc));
  -webkit-background-clip:text;background-clip:text;color:transparent;
  animation:rise .7s ease both;
}
.tag{color:var(--mut);font-size:1.05rem;margin:0 0 28px;max-width:34ch;animation:rise .7s .08s ease both}
.panel{
  border:1px solid var(--line);border-radius:18px;padding:16px;
  background:rgba(10,14,24,.55);backdrop-filter:blur(10px);
  animation:rise .7s .14s ease both;
}
label{display:block;font-size:.78rem;letter-spacing:.08em;text-transform:uppercase;color:var(--mut);margin:0 0 8px}
input,select{
  width:100%;height:48px;border-radius:12px;border:1px solid var(--line);
  background:#0b0f18;color:var(--ink);padding:0 14px;font:600 15px var(--font-body);outline:0;
}
input:focus{border-color:rgba(255,154,31,.65);box-shadow:0 0 0 3px rgba(255,154,31,.15)}
.row{display:flex;gap:10px;margin-top:12px;flex-wrap:wrap}
.btn{
  appearance:none;border:0;border-radius:12px;cursor:pointer;
  font:700 15px var(--font-body);padding:13px 18px;flex:1;min-width:140px;
  transition:transform .15s ease,filter .15s ease;
}
.btn:active{transform:scale(.98)}
.btn:disabled{opacity:.45;cursor:not-allowed}
.btn.pri{background:linear-gradient(135deg,var(--acc),#ff7a00);color:#14110c}
.btn.ghost{background:transparent;border:1px solid var(--line);color:var(--ink)}
.status{min-height:1.4em;margin:14px 2px 0;color:var(--mut);font-size:.95rem}
.status.bad{color:var(--bad)}.status.ok{color:var(--ok)}
.bar{
  margin-top:12px;height:8px;border-radius:999px;background:rgba(255,255,255,.08);overflow:hidden;
  opacity:0;transition:opacity .25s ease;
}
.bar.on{opacity:1}
.bar>i{
  display:block;height:100%;width:0%;border-radius:inherit;
  background:linear-gradient(90deg,var(--acc),var(--acc2));
  transition:width .35s ease;
  box-shadow:0 0 18px rgba(255,154,31,.45);
}
.done{display:none;margin-top:18px;padding-top:14px;border-top:1px solid var(--line)}
.done.on{display:block;animation:rise .45s ease both}
.done h2{font-family:var(--font-display);font-size:1.35rem;margin:0 0 4px}
.done p{margin:0 0 14px;color:var(--mut);font-size:.92rem}
.hint{margin-top:22px;color:var(--mut);font-size:.82rem;line-height:1.5}
a{color:var(--acc2)}
@keyframes rise{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>
</head>
<body>
<main class="wrap">
  <h1 class="brand">FastDecrypt</h1>
  <p class="tag">Paste an App Store link. Decrypt on our Mac. Download up to ${maxGb}&nbsp;GB over HTTPS.</p>
  <form class="panel" id="f" autocomplete="off">
    <label for="url">App Store link</label>
    <input id="url" name="url" type="url" inputmode="url" placeholder="https://apps.apple.com/…/id…" required/>
    <label for="ver" style="margin-top:12px">Version (optional)</label>
    <input id="ver" name="ver" type="text" placeholder="latest" maxlength="30"/>
    <div class="row">
      <button class="btn pri" type="submit" id="go">Decrypt</button>
    </div>
    <div class="bar" id="bar"><i id="fill"></i></div>
    <p class="status" id="st" role="status"></p>
    <div class="done" id="done">
      <h2 id="name">App.ipa</h2>
      <p id="meta"></p>
      <div class="row">
        <a class="btn pri" id="dl" href="#">Download IPA</a>
        <a class="btn ghost" id="oin" href="#" target="_blank" rel="noopener">Open in…</a>
      </div>
    </div>
  </form>
  <p class="hint">Public downloads expire after a few hours. Discord / Telegram bots use the same Mac. · build ${String(build || "").replace(/[<>]/g, "")}</p>
</main>
<script>
(function(){
  var MAX_GB=${JSON.stringify(Number(maxGb))};
  function $(id){return document.getElementById(id);}
  function token(){
    try{
      var k='fd:webBearer';
      var t=localStorage.getItem(k);
      if(!t||t.length<16){t='web-'+Array.from(crypto.getRandomValues(new Uint8Array(16))).map(function(b){return b.toString(16).padStart(2,'0');}).join('');localStorage.setItem(k,t);}
      return t;
    }catch(e){return 'web-anon';}
  }
  function headers(){
    return {'content-type':'application/json','authorization':'Bearer '+token()};
  }
  function say(msg,kind){
    var el=$('st');el.textContent=msg||'';el.className='status'+(kind?' '+kind:'');
  }
  function setPct(n){
    var p=Math.max(0,Math.min(100,Math.round(Number(n)||0)));
    $('bar').classList.add('on');
    $('fill').style.width=p+'%';
  }
  function fmt(n){
    n=Number(n)||0;
    if(n>=1e9)return (n/1e9).toFixed(2)+' GB';
    if(n>=1e6)return (n/1e6).toFixed(1)+' MB';
    return Math.max(1,Math.round(n/1e3))+' KB';
  }
  var timer=null,cur='';
  function stop(){clearTimeout(timer);timer=null;$('go').disabled=false;}
  function poll(id){
    cur=id;
    fetch('/api/decrypt/'+id,{headers:headers()}).then(function(r){return r.json();}).then(function(j){
      if(cur!==id)return;
      if(!j.ok){stop();say(j.error||'Request expired.','bad');return;}
      setPct(j.progress||0);
      if(j.status==='done'){
        stop();say('Done','ok');
        $('name').textContent=j.name||'App';
        $('meta').textContent=(j.bid?j.bid+' · ':'')+(j.ver?'v'+j.ver+' · ':'')+fmt(j.size)+' · max '+MAX_GB+' GB';
        var url=j.downloadUrl||(j.up?('/api/ipa/file/'+j.up):'');
        $('dl').href=url||'#';
        $('oin').href=j.openMenuUrl||'#';
        $('oin').style.display=j.openMenuUrl?'':'none';
        $('done').classList.add('on');
        return;
      }
      if(j.status==='error'){stop();say(j.error||'Decrypt failed.','bad');return;}
      say(j.msg||'Working…');
      timer=setTimeout(function(){poll(id);},1200);
    }).catch(function(){timer=setTimeout(function(){poll(id);},2500);});
  }
  $('f').addEventListener('submit',function(e){
    e.preventDefault();
    var url=$('url').value.trim();
    var ver=$('ver').value.trim();
    if(!/^https:\\/\\/(apps|itunes)\\.apple\\.com\\//i.test(url)){say('Paste a full App Store link.','bad');return;}
    $('go').disabled=true;$('done').classList.remove('on');say('Starting…');setPct(1);
    fetch('/api/decrypt',{method:'POST',headers:headers(),body:JSON.stringify({url:url,version:ver,source:'web'})}).then(function(r){return r.json();}).then(function(j){
      if(!j.ok){$('go').disabled=false;say(j.error||'Could not start.','bad');return;}
      poll(j.id);
    }).catch(function(){$('go').disabled=false;say('Network error.','bad');});
  });
})();
</script>
</body>
</html>`;
  const body = Buffer.from(html, "utf8");
  res.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Content-Length": body.length,
    "Cache-Control": "no-store",
  });
  res.end(body);
}

module.exports = {
  WEB_MAX_BYTES,
  sendHtml,
};
