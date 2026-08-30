/// Static single-page web UI served by [ApiWebServer]. Vanilla HTML/CSS/JS —
/// no build step. An Apidog-like workspace: a sidebar tree (search + method
/// filter + checkboxes), a request builder with editable Params/Headers/Body/
/// Auth tabs and a Send (try-it) action, a live Response view, and a Code
/// preview tab. Talks to the server over:
///   GET  /api/tree
///   GET  /api/endpoint?index=N
///   GET  /api/preview?index=N
///   POST /api/try
///   POST /api/generate
///   POST /api/relogin
///
/// Kept as a Dart string constant so the package ships self-contained.
const String indexHtml = r'''<!DOCTYPE html>
<html lang="en" dir="ltr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>api2dart</title>
<style>
  :root{
    --bg:#0b1120;--bg2:#0f172a;--panel:#161f33;--panel2:#1b2740;
    --ink:#e2e8f0;--muted:#94a3b8;--faint:#64748b;--line:#27324a;
    --accent:#38bdf8;--accent2:#0ea5e9;--green:#22c55e;--red:#ef4444;
    --amber:#f59e0b;--purple:#a78bfa;--code:#070d18;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%}
  body{background:var(--bg);color:var(--ink);
    font-family:"Segoe UI",Tahoma,system-ui,sans-serif;font-size:14px;
    display:flex;flex-direction:column;overflow:hidden}
  button{font-family:inherit}
  .topbar{display:flex;align-items:center;gap:14px;padding:11px 18px;
    background:var(--bg2);border-bottom:1px solid var(--line);flex:0 0 auto}
  .logo{font-size:18px;font-weight:800}.logo .d{color:var(--accent)}
  .src{color:var(--muted);font-size:13px}.src b{color:var(--ink)}
  .top-meta{display:flex;gap:8px;margin-left:6px}
  .chip{background:var(--panel);border:1px solid var(--line);border-radius:999px;
    padding:4px 11px;font-size:12px;color:var(--muted)}.chip b{color:var(--accent)}
  /* Token status: clickable, and colored by whether auth is currently healthy */
  .chip.tok{cursor:pointer;font:inherit;font-size:12px;line-height:normal}
  .chip.tok:hover{border-color:var(--accent)}
  .chip.tok.ok b{color:var(--green)}
  .chip.tok.bad{border-color:var(--red)}.chip.tok.bad b{color:var(--red)}
  .chip.tok.none b{color:var(--muted)}
  .spacer{margin-left:auto}
  .btn{border:1px solid var(--line);background:var(--panel);color:var(--ink);
    padding:8px 15px;border-radius:9px;font-size:13px;font-weight:600;cursor:pointer;transition:.15s}
  .btn:hover{border-color:var(--accent)}
  .btn.primary{background:var(--accent);color:#04263a;border-color:var(--accent)}
  .btn.primary:hover{filter:brightness(1.08)}
  .btn.send{background:var(--green);color:#052e16;border-color:var(--green)}
  .btn:disabled{opacity:.45;cursor:not-allowed}
  .selinfo{color:var(--muted);font-size:13px}

  .main{flex:1;display:flex;min-height:0}
  /* sidebar */
  .side{width:340px;flex:0 0 auto;background:var(--bg2);border-right:1px solid var(--line);
    display:flex;flex-direction:column;min-height:0}
  .side-tools{padding:12px;border-bottom:1px solid var(--line);display:flex;flex-direction:column;gap:9px}
  .search{width:100%;background:var(--panel);border:1px solid var(--line);color:var(--ink);
    border-radius:9px;padding:9px 12px;font-size:13px;outline:none}
  .search:focus{border-color:var(--accent)}
  .filters{display:flex;gap:5px;flex-wrap:wrap}
  .mf{font-family:monospace;font-size:11px;font-weight:700;padding:4px 9px;border-radius:7px;
    cursor:pointer;border:1px solid var(--line);background:var(--panel);color:var(--muted);user-select:none}
  .mf.on{color:var(--ink);border-color:var(--accent)}
  .mf.on.m-GET{background:#0e2a17}.mf.on.m-POST{background:#0c2336}
  .mf.on.m-PUT{background:#2a230c}.mf.on.m-PATCH{background:#2a1c0c}.mf.on.m-DELETE{background:#2a1212}
  .side-actions{display:flex;gap:7px;align-items:center}
  .selall{display:flex;align-items:center;gap:7px;cursor:pointer;user-select:none;
    color:var(--accent);font-size:12px;font-weight:600}
  .selall input{width:15px;height:15px;accent-color:var(--accent);cursor:pointer}
  .link{background:none;border:none;color:var(--accent);font-size:12px;cursor:pointer;padding:2px 4px;font-weight:600}
  .tree{flex:1;overflow:auto;padding:6px 0}
  .folder{margin-bottom:2px}
  .folder-head{display:flex;align-items:center;gap:9px;padding:11px 14px;cursor:pointer;
    user-select:none;font-weight:700;font-size:13.5px;color:var(--ink);border-radius:8px;
    margin:1px 6px;transition:background .12s}
  .folder-head:hover{background:var(--panel)}
  .folder-head .folder-box{width:16px;height:16px;accent-color:var(--accent);cursor:pointer;flex:0 0 auto}
  .folder-head .caret{font-size:11px;width:12px;color:var(--accent);transition:transform .15s;flex:0 0 auto}
  .folder-head.collapsed .caret{transform:rotate(-90deg)}
  .folder-head .fico{font-size:15px;flex:0 0 auto}
  .folder-head .fname{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .folder-head .fc{margin-left:auto;font-weight:600;font-size:11px;color:var(--faint);
    background:var(--panel2);border-radius:10px;padding:2px 9px;flex:0 0 auto}
  /* endpoint rows — indented under the folder with a connecting guide line */
  .folder-kids{position:relative;margin-left:24px;padding-left:2px;
    border-left:1.5px solid var(--line)}
  .ep{display:flex;align-items:center;gap:10px;padding:10px 12px 10px 16px;cursor:pointer;
    border-left:2px solid transparent;border-radius:0 8px 8px 0;margin-right:6px;
    position:relative;transition:background .12s}
  .ep::before{content:"";position:absolute;left:-2px;top:50%;width:11px;height:1.5px;
    background:var(--line)}
  .ep:hover{background:var(--panel)}
  .ep.active{background:var(--panel2);border-left-color:var(--accent)}
  .ep.active::before{background:var(--accent)}
  .ep input{width:16px;height:16px;accent-color:var(--accent);cursor:pointer;flex:0 0 auto}
  .method{font-family:monospace;font-size:10.5px;font-weight:700;padding:3px 7px;border-radius:6px;
    min-width:52px;text-align:center;flex:0 0 auto;letter-spacing:.3px}
  .m-GET{background:#0e2a17;color:#86efac}.m-POST{background:#0c2336;color:#7dd3fc}
  .m-PUT{background:#2a230c;color:#fcd34d}.m-PATCH{background:#2a1c0c;color:#fdba74}
  .m-DELETE{background:#2a1212;color:#fca5a5}
  .ep .nm{font-size:13.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .ep.active .nm{color:#fff}
  .ep .lock{color:var(--amber);font-size:12px;flex:0 0 auto}
  .ep .gen-tag{margin-left:auto;color:var(--green);font-size:11px;font-weight:700;flex:0 0 auto}
  .ep .gen-tag+.lock{margin-left:6px}
  .ep .lock:only-of-type{margin-left:auto}
  .empty{color:var(--faint);text-align:center;padding:30px 16px;font-size:13px}

  /* detail */
  .detail{flex:1;display:flex;flex-direction:column;min-width:0;background:var(--bg)}
  .blank{flex:1;display:flex;align-items:center;justify-content:center;color:var(--faint);font-size:14px}
  .reqline{display:flex;gap:9px;padding:14px 18px;border-bottom:1px solid var(--line);align-items:center}
  .reqline select{background:var(--panel);border:1px solid var(--line);color:var(--ink);
    border-radius:8px;padding:8px 10px;font-family:monospace;font-weight:700;font-size:12px;outline:none}
  .reqline .url{flex:1;background:var(--panel);border:1px solid var(--line);color:var(--ink);
    border-radius:8px;padding:8px 12px;font-family:monospace;font-size:12.5px;outline:none}
  .reqline .url:focus{border-color:var(--accent)}
  .epname{padding:10px 18px 0;font-weight:700;font-size:15px}
  .dirty-tag{margin-left:9px;font-size:10px;font-weight:600;color:var(--amber);
    background:#3b2f12;padding:2px 8px;border-radius:8px;vertical-align:middle}
  .epdesc{padding:2px 18px 0;color:var(--muted);font-size:12.5px}
  .tabs{display:flex;gap:2px;padding:10px 18px 0;border-bottom:1px solid var(--line)}
  .tab{padding:8px 14px;font-size:13px;font-weight:600;color:var(--muted);cursor:pointer;
    border-bottom:2px solid transparent;user-select:none}
  .tab:hover{color:var(--ink)}
  .tab.on{color:var(--accent);border-bottom-color:var(--accent)}
  .tab .badge{background:var(--panel2);color:var(--muted);font-size:10px;padding:1px 6px;border-radius:8px;margin-left:5px}
  .tabwrap{flex:1;overflow:auto;padding:14px 18px}
  .pane{display:none}.pane.on{display:block}
  table.kv{width:100%;border-collapse:collapse}
  table.kv td{padding:4px 4px}
  table.kv input{width:100%;background:var(--panel);border:1px solid var(--line);color:var(--ink);
    border-radius:7px;padding:7px 10px;font-size:12.5px;font-family:monospace;outline:none}
  table.kv input:focus{border-color:var(--accent)}
  table.kv td.del{width:30px;text-align:center}
  .icon-btn{background:none;border:none;color:var(--faint);cursor:pointer;font-size:15px;padding:2px 6px}
  .icon-btn:hover{color:var(--red)}
  .addrow{margin-top:8px;color:var(--accent);background:none;border:1px dashed var(--line);
    border-radius:8px;padding:7px 12px;font-size:12.5px;cursor:pointer;font-weight:600}
  .addrow:hover{border-color:var(--accent)}
  .bodybar{display:flex;gap:8px;margin-bottom:10px;align-items:center}
  .bodybar select{background:var(--panel);border:1px solid var(--line);color:var(--ink);
    border-radius:7px;padding:6px 9px;font-size:12px;outline:none}
  textarea.raw{width:100%;min-height:200px;background:var(--code);border:1px solid var(--line);
    color:#cbd5e1;border-radius:9px;padding:12px;font-family:"SF Mono",Menlo,monospace;
    font-size:12.5px;line-height:1.6;outline:none;resize:vertical}
  .authrow{display:flex;gap:9px;align-items:center;margin-bottom:10px}
  .authrow select,.authrow input{background:var(--panel);border:1px solid var(--line);color:var(--ink);
    border-radius:8px;padding:8px 11px;font-size:12.5px;outline:none}
  .authrow input{flex:1;font-family:monospace}
  /* Output tab */
  .out-grid{display:flex;flex-direction:column;gap:12px;max-width:560px}
  .out-field{display:flex;align-items:center;gap:12px;position:relative}
  .out-field>span{width:110px;flex:0 0 auto;color:var(--muted);font-size:12.5px}
  .out-field input,.out-field select{flex:1;background:var(--panel);border:1px solid var(--line);
    color:var(--ink);border-radius:8px;padding:8px 11px;font-size:12.5px;font-family:monospace;outline:none}
  .out-field input:focus,.out-field select:focus{border-color:var(--accent)}
  .out-apply{flex:0 0 auto;font-size:11px}
  .out-hint{margin-top:14px;font-size:12px;color:var(--faint);font-family:monospace;line-height:1.7;
    background:var(--code);border:1px solid var(--line);border-radius:8px;padding:11px 13px}
  .out-hint b{color:var(--accent)}
  pre.code{background:var(--code);border:1px solid var(--line);border-radius:9px;padding:14px 16px;
    font-family:"SF Mono",Menlo,monospace;font-size:12.5px;line-height:1.65;color:#cbd5e1;
    overflow:auto;white-space:pre;max-height:100%}
  .codehead{display:flex;align-items:center;gap:10px;margin-bottom:10px}
  .codehead .fn{font-family:monospace;font-size:12.5px;color:var(--accent)}

  /* response */
  .resp{flex:0 0 auto;height:42%;min-height:160px;display:flex;flex-direction:column;
    border-top:1px solid var(--line);background:var(--bg2);transition:height .18s ease}
  .resp.expanded{height:78%}
  .resp-head{display:flex;align-items:center;gap:12px;padding:9px 16px;border-bottom:1px solid var(--line);flex:0 0 auto}
  .resp-head .ttl{font-weight:700;font-size:13px}
  .status{font-family:monospace;font-weight:700;font-size:12px;padding:3px 9px;border-radius:6px}
  .status.ok{background:#0e2a17;color:#86efac}.status.bad{background:#2a1212;color:#fca5a5}
  .status.warn{background:#2a230c;color:#fcd34d}
  .resp-meta{color:var(--muted);font-size:12px;font-family:monospace}
  /* Body/Headers tabs in the response header */
  .resp-tabs{display:flex;gap:2px}
  .rtab{font-size:12px;font-weight:600;color:var(--muted);cursor:pointer;padding:5px 11px;
    border-radius:7px;user-select:none}
  .rtab:hover{color:var(--ink)}
  .rtab.on{color:var(--accent);background:var(--panel)}
  .rtab .badge{background:var(--panel2);color:var(--muted);font-size:10px;padding:1px 6px;border-radius:8px;margin-left:4px}
  .iconbtn{background:none;border:1px solid var(--line);color:var(--muted);cursor:pointer;
    font-size:13px;border-radius:7px;padding:4px 9px;line-height:1}
  .iconbtn:hover{color:var(--ink);border-color:var(--accent)}
  .resp-body{flex:1;overflow:auto;padding:0;min-height:0}
  .resp-body pre{padding:14px 18px;font-family:"SF Mono",Menlo,monospace;font-size:12.5px;
    line-height:1.65;white-space:pre-wrap;word-break:break-word;color:#cbd5e1}
  .resp-empty{color:var(--faint);padding:20px 18px;font-size:13px}
  /* response headers pane (table) */
  .rh-table{width:100%;border-collapse:collapse;font-family:monospace;font-size:12px}
  .rh-table td{padding:7px 18px;border-bottom:1px solid var(--line);vertical-align:top;word-break:break-all}
  .rh-table td.k{color:var(--accent);width:34%;font-weight:600}
  .rh-table td.v{color:var(--muted)}
  .rh-url{padding:10px 18px;border-bottom:1px solid var(--line);font-family:monospace;font-size:11.5px;
    color:var(--faint);word-break:break-all}.rh-url b{color:var(--accent)}
  /* JSON syntax highlighting */
  .j-key{color:#7dd3fc}.j-str{color:#86efac}.j-num{color:#fcd34d}
  .j-bool{color:#c084fc}.j-null{color:#f87171}.j-punc{color:#64748b}
  .spinner{display:inline-block;width:13px;height:13px;border:2px solid var(--line);
    border-top-color:var(--accent);border-radius:50%;animation:spin .7s linear infinite;vertical-align:-2px}
  @keyframes spin{to{transform:rotate(360deg)}}
  /* generate results modal-ish panel */
  .genres{position:fixed;right:18px;bottom:18px;width:420px;max-height:60vh;overflow:auto;
    background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px 18px;
    box-shadow:0 20px 50px rgba(0,0,0,.5);z-index:50}
  .genres h3{font-size:14px;margin-bottom:10px;display:flex;align-items:center}
  .genres .x{margin-left:auto;cursor:pointer;color:var(--muted);background:none;border:none;font-size:16px}
  .gr-row{display:flex;gap:8px;padding:4px 0;font-size:12px;font-family:monospace}
  .gr-row .ok{color:var(--green)}.gr-row .bad{color:var(--red)}.gr-row .warn{color:var(--amber)}
  .gr-sub{color:var(--muted)}
  .gr-logs{margin-top:10px}
  .gr-logs summary{cursor:pointer;color:var(--muted);font-size:12px;user-select:none}
  .gr-logs summary:hover{color:var(--ink)}
  .gr-logs pre{margin-top:8px;background:#060b16;border:1px solid var(--line);border-radius:8px;
    padding:10px;font-size:11px;color:var(--muted);max-height:160px;overflow:auto;white-space:pre-wrap}
  /* folder picker modal */
  .out-browse{padding:6px 11px;font-size:12px;flex:0 0 auto}
  .pick-overlay{position:fixed;inset:0;z-index:80;background:rgba(0,0,0,.55);
    display:flex;align-items:center;justify-content:center;padding:20px}
  .pick{width:520px;max-width:100%;max-height:78vh;display:flex;flex-direction:column;
    background:var(--panel);border:1px solid var(--line);border-radius:14px;
    box-shadow:0 24px 60px rgba(0,0,0,.55);overflow:hidden}
  .pick-head{display:flex;align-items:center;gap:10px;padding:14px 18px;border-bottom:1px solid var(--line)}
  .pick-title{font-weight:700;font-size:14px}.pick-head .iconbtn{margin-left:auto}
  .pick-path{padding:10px 18px;font-family:monospace;font-size:12px;color:var(--muted);
    border-bottom:1px solid var(--line);word-break:break-all}
  .pick-path .crumb{color:var(--accent);cursor:pointer}
  .pick-path .crumb:hover{text-decoration:underline}
  .pick-list{flex:1;overflow:auto;padding:6px 0;min-height:120px}
  .pick-item{display:flex;align-items:center;gap:10px;padding:9px 18px;cursor:pointer;font-size:13px;user-select:none}
  .pick-item:hover{background:var(--panel2)}
  .pick-item .ico{font-size:15px}
  .pick-item.up{color:var(--muted)}
  .pick-empty{color:var(--faint);text-align:center;padding:24px;font-size:13px}
  .pick-foot{display:flex;align-items:center;gap:12px;padding:13px 18px;border-top:1px solid var(--line)}
  .tok-body{padding:16px 18px;display:flex;flex-direction:column;gap:12px}
  .tok-body input{background:var(--panel);border:1px solid var(--line);color:var(--ink);
    border-radius:8px;padding:9px 11px;font-size:13px;font-family:monospace;width:100%}
  .tok-body input:focus{border-color:var(--accent);outline:none}
  .pick-sel{flex:1;font-family:monospace;font-size:12px;color:var(--muted);word-break:break-all}
  .hidden{display:none!important}

  /* hamburger + overlay (hidden on desktop) */
  .hamburger{display:none;background:var(--panel);border:1px solid var(--line);
    color:var(--ink);font-size:16px;border-radius:8px;padding:6px 11px;cursor:pointer;flex:0 0 auto}
  .hamburger:hover{border-color:var(--accent)}
  .side-overlay{display:none}

  /* Tablet / small laptop: narrower sidebar, wrap top meta */
  @media (max-width:1024px){
    .side{width:280px}
    .top-meta{display:none}
  }

  /* Mobile: sidebar becomes a slide-in drawer; builder + response stack */
  @media (max-width:760px){
    .hamburger{display:inline-flex;align-items:center}
    .topbar{flex-wrap:wrap;gap:10px;padding:10px 12px}
    .logo{font-size:16px}
    .src{display:none}
    #generate{font-size:12px;padding:7px 11px}
    .selinfo{font-size:12px}

    .main{position:relative}
    .side{position:absolute;z-index:40;top:0;bottom:0;left:0;width:86%;max-width:340px;
      transform:translateX(-100%);transition:transform .22s ease;
      box-shadow:6px 0 24px rgba(0,0,0,.5)}
    .side.open{transform:translateX(0)}
    .side-overlay{position:absolute;inset:0;z-index:30;background:rgba(0,0,0,.5);
      opacity:0;pointer-events:none;transition:opacity .22s}
    .side-overlay.open{display:block;opacity:1;pointer-events:auto}

    /* request line + tabs scroll horizontally instead of squashing */
    .reqline{flex-wrap:wrap}
    .reqline .url{min-width:0;flex:1 1 100%;order:3}
    .tabs{overflow-x:auto;white-space:nowrap}
    .tabwrap{padding:12px}
    .epname{padding:10px 12px 0}.epdesc{padding:2px 12px 0}

    /* response panel taller on mobile (no side-by-side detail) */
    .resp{max-height:55%}
    .resp-head{padding:9px 12px}.resp-body pre{padding:12px}

    .genres{right:8px;left:8px;bottom:8px;width:auto;max-height:55vh}
  }
</style>
</head>
<body>
<div class="topbar">
  <button class="hamburger" id="menuToggle" title="Toggle endpoints" aria-label="Toggle endpoints">☰</button>
  <span class="logo">api2dart<span class="d">.</span></span>
  <span class="src">Source: <b id="sourceName">…</b></span>
  <div class="top-meta" id="topMeta"></div>
  <span class="spacer"></span>
  <span class="selinfo" id="selInfo">0 selected</span>
  <button class="btn primary" id="generate" disabled>Generate selected</button>
</div>

<div class="main">
  <div class="side-overlay" id="sideOverlay"></div>
  <aside class="side">
    <div class="side-tools">
      <input class="search" id="search" placeholder="Search endpoints…" autocomplete="off">
      <div class="filters" id="filters"></div>
      <div class="side-actions">
        <label class="selall"><input type="checkbox" id="selectAllBox"><span id="selectAllLabel">Select all</span></label>
        <span class="fc" id="visCount" style="margin-left:auto;color:var(--faint);font-size:11px"></span>
      </div>
    </div>
    <div class="tree" id="tree"><div class="empty">Loading…</div></div>
  </aside>

  <section class="detail">
    <div class="blank" id="blank">← Select an endpoint to inspect, edit, send, or preview its code.</div>

    <div class="hidden" id="builder" style="flex:1;display:flex;flex-direction:column;min-height:0">
      <div class="epname" id="epName"></div>
      <div class="epdesc" id="epDesc"></div>
      <div class="reqline">
        <select id="mMethod"></select>
        <input class="url" id="mUrl" placeholder="https://api.example.com/path">
        <button class="btn send" id="send">Send</button>
      </div>
      <div class="tabs" id="tabs">
        <div class="tab on" data-pane="params">Params <span class="badge" id="bParams">0</span></div>
        <div class="tab" data-pane="headers">Headers <span class="badge" id="bHeaders">0</span></div>
        <div class="tab" data-pane="body">Body</div>
        <div class="tab" data-pane="auth">Auth</div>
        <div class="tab" data-pane="output">Output</div>
        <div class="tab" data-pane="code">Code</div>
      </div>
      <div class="tabwrap">
        <div class="pane on" id="pane-params"></div>
        <div class="pane" id="pane-headers"></div>
        <div class="pane" id="pane-body">
          <div class="bodybar">
            <select id="bodyKind">
              <option value="none">No body</option>
              <option value="raw">raw (JSON)</option>
              <option value="formdata">form-data</option>
              <option value="urlencoded">x-www-form-urlencoded</option>
            </select>
          </div>
          <textarea class="raw hidden" id="bodyRaw" placeholder='{ "key": "value" }'></textarea>
          <div id="bodyFields" class="hidden"></div>
        </div>
        <div class="pane" id="pane-auth">
          <div class="authrow">
            <select id="authType">
              <option value="none">No auth</option>
              <option value="bearer">Bearer</option>
              <option value="basic">Basic</option>
              <option value="apiKey">API key</option>
            </select>
            <input id="authToken" placeholder="token / value" class="hidden">
          </div>
          <div class="epdesc" style="padding:0">Auth is sent as a header when you press Send.</div>
        </div>
        <div class="pane" id="pane-output">
          <div class="out-grid">
            <label class="out-field">
              <span>Output dir</span>
              <input id="outDir" placeholder="(default)">
              <button class="btn out-browse" id="outBrowse" type="button">📁 Browse</button>
              <button class="link out-apply" id="outApplyDir" type="button">apply to all</button>
            </label>
            <label class="out-field">
              <span>File name</span>
              <input id="outFile" placeholder="(default)">
            </label>
            <label class="out-field">
              <span>Action class</span>
              <input id="outAction" placeholder="(default)">
            </label>
            <label class="out-field">
              <span>Response class</span>
              <input id="outResponse" placeholder="(default)">
            </label>
            <label class="out-field">
              <span>Mode</span>
              <select id="outMode">
                <option value="default">Default</option>
                <option value="auto">Auto (detect api_request)</option>
                <option value="action">Action + Response</option>
                <option value="response-only">Response only</option>
              </select>
            </label>
          </div>
          <div class="out-hint" id="outHint"></div>
        </div>
        <div class="pane" id="pane-code">
          <div class="codehead"><span class="fn" id="codeFile"></span>
            <button class="btn" id="copyCode" style="margin-left:auto;padding:5px 11px;font-size:12px">Copy</button></div>
          <pre class="code" id="codeBox">Select the Code tab to preview…</pre>
        </div>
      </div>
    </div>

    <div class="resp hidden" id="resp">
      <div class="resp-head">
        <span class="ttl">Response</span>
        <span id="respStatus"></span>
        <span class="resp-meta" id="respMeta"></span>
        <span class="spacer" style="margin-left:auto"></span>
        <div class="resp-tabs" id="respTabs">
          <span class="rtab on" data-rt="body">Body</span>
          <span class="rtab" data-rt="headers">Headers <span class="badge" id="rhCount">0</span></span>
        </div>
        <button class="iconbtn" id="respExpand" title="Expand / collapse">⤢</button>
        <button class="iconbtn" id="respClose" title="Hide">✕</button>
      </div>
      <div class="resp-body" id="respBody"></div>
      <div class="resp-body hidden" id="respHeadersPane"></div>
    </div>
  </section>
</div>

<div class="genres hidden" id="genres"></div>

<div class="pick-overlay hidden" id="pickOverlay">
  <div class="pick">
    <div class="pick-head">
      <span class="pick-title">Choose output folder</span>
      <button class="iconbtn" id="pickClose" title="Close">✕</button>
    </div>
    <div class="pick-path" id="pickPath"></div>
    <div class="pick-list" id="pickList"></div>
    <div class="pick-foot">
      <span class="pick-sel" id="pickSel"></span>
      <button class="btn primary" id="pickUse">Use this folder</button>
    </div>
  </div>
</div>

<div class="pick-overlay hidden" id="tokOverlay">
  <div class="pick">
    <div class="pick-head">
      <span class="pick-title">Auth token</span>
      <button class="iconbtn" id="tokClose" title="Close">✕</button>
    </div>
    <div class="tok-body">
      <div class="hint" id="tokHint"></div>
      <input id="tokOtp" class="hidden" placeholder="OTP code">
      <input id="tokPaste" placeholder="…or paste a token here">
      <div class="hint" id="tokMsg"></div>
    </div>
    <div class="pick-foot">
      <button class="btn" id="tokRelogin">Re-login now</button>
      <span class="spacer"></span>
      <button class="btn primary" id="tokUse">Use pasted token</button>
    </div>
  </div>
</div>

<script>
const $=(s,el=document)=>el.querySelector(s);
const $$=(s,el=document)=>[...el.querySelectorAll(s)];
const METHODS=['GET','POST','PUT','PATCH','DELETE'];
let TREE=null, CUR=null, activeFilters=new Set();

function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}

async function jget(u){const r=await fetch(u);return r.json();}
async function jpost(u,b){const r=await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});return r.json();}

// Flat index of all endpoint nodes (by index) — built once from the nested
// roots, used for search/filter, the request builder, and select-all.
const EP_BY_INDEX={};
function indexEndpoints(nodes){
  for(const n of nodes){
    if(n.type==='endpoint')EP_BY_INDEX[n.index]=n;
    else indexEndpoints(n.children);
  }
}

async function load(){
  TREE=await jget('/api/tree');
  indexEndpoints(TREE.roots);
  $('#sourceName').textContent=TREE.sourceName;
  $('#topMeta').innerHTML=
    `<span class="chip">Endpoints <b>${TREE.total}</b></span>`+
    `<span class="chip">Mode <b>${TREE.mode}</b></span>`+
    `<span class="chip">Out <b>${esc(TREE.outputDir)}</b></span>`+
    `<button class="chip tok" id="tokChip" title="Auth token — click to refresh"></button>`;
  renderTokenChip(TREE.hasToken?'ok':'none', TREE.token||'');
  $('#tokChip').onclick=openTokenModal;
  // method filters
  $('#filters').innerHTML=METHODS.map(m=>`<span class="mf m-${m}" data-m="${m}">${m}</span>`).join('');
  $$('.mf').forEach(f=>f.onclick=()=>{const m=f.dataset.m;
    if(activeFilters.has(m)){activeFilters.delete(m);f.classList.remove('on');}
    else{activeFilters.add(m);f.classList.add('on');}renderTree();});
  // populate method dropdown
  $('#mMethod').innerHTML=METHODS.map(m=>`<option value="${m}">${m}</option>`).join('');
  renderTree();
}

// An endpoint passes the current search/method filters.
function epMatches(ep){
  const q=$('#search').value.trim().toLowerCase();
  if(activeFilters.size && !activeFilters.has(ep.method))return false;
  if(q && !(`${ep.name} ${ep.path} ${ep.method}`.toLowerCase().includes(q)))return false;
  return true;
}
// All endpoint indexes currently visible (used by master/select-all).
function filtered(){return Object.values(EP_BY_INDEX).filter(epMatches);}

// Collects the visible endpoint indexes under a node (folder or endpoint).
function visibleIdxsOf(node){
  if(node.type==='endpoint')return epMatches(node)?[node.index]:[];
  return node.children.flatMap(visibleIdxsOf);
}

function renderTree(){
  const tree=$('#tree');
  const vis=filtered();
  $('#visCount').textContent=`${vis.length} shown`;
  syncMaster();
  if(!vis.length){tree.innerHTML='<div class="empty">No endpoints match.</div>';return;}
  tree.innerHTML='';
  // When searching, auto-expand so matches show; otherwise start collapsed.
  const expand=$('#search').value.trim().length>0;
  for(const node of TREE.roots){
    const el=renderNode(node,0,expand);
    if(el)tree.appendChild(el);
  }
}

// Recursively renders a folder or endpoint node, mirroring the terminal
// selector's nested tree. Returns null when nothing under it is visible.
function renderNode(node,depth,expand){
  if(node.type==='endpoint'){
    return epMatches(node)?renderEndpoint(node):null;
  }
  // folder
  const idxs=visibleIdxsOf(node);
  if(!idxs.length)return null;  // hide empty/filtered-out folders
  const f=document.createElement('div');
  f.className='folder';
  const head=document.createElement('div');
  head.className='folder-head'+(expand?'':' collapsed');
  head.innerHTML=
    `<input type="checkbox" class="folder-box" title="Select all in this folder">`+
    `<span class="caret">▾</span><span class="fico">📁</span>`+
    `<span class="fname">${esc(node.name)}</span><span class="fc">${idxs.length}</span>`;
  const kids=document.createElement('div');
  kids.className='folder-kids'+(expand?'':' hidden');
  for(const child of node.children){
    const el=renderNode(child,depth+1,expand);
    if(el)kids.appendChild(el);
  }
  const fbox=head.querySelector('.folder-box');
  fbox.dataset.idxs=JSON.stringify(idxs);
  // ◉ folder checkbox: selects/deselects every visible endpoint beneath it,
  // updating the rows + ancestor folders IN PLACE (no full re-render, so
  // expand/collapse state and scroll position are preserved).
  fbox.onclick=e=>{
    e.stopPropagation();
    const on=e.target.checked;
    idxs.forEach(i=>on?SELECTED.add(i):SELECTED.delete(i));
    // reflect on the descendant row checkboxes currently in the DOM
    idxs.forEach(i=>{const cb=tree.querySelector(`.ep input[data-idx="${i}"]`);if(cb)cb.checked=on;});
    refreshChecks();
  };
  syncFolderBox(fbox,idxs);
  head.onclick=()=>{head.classList.toggle('collapsed');kids.classList.toggle('hidden');};
  f.appendChild(head);f.appendChild(kids);
  return f;
}

function renderEndpoint(ep){
  const row=document.createElement('div');
  row.className='ep'+(CUR===ep.index?' active':'');
  row.dataset.idx=ep.index;
  // label mirrors the terminal: METHOD badge + path (name as tooltip)
  row.innerHTML=
    `<input type="checkbox" data-idx="${ep.index}" ${SELECTED.has(ep.index)?'checked':''}>`+
    `<span class="method m-${ep.method}">${ep.method}</span>`+
    `<span class="nm" title="${esc(ep.name)}">${esc(ep.path)}</span>`+
    (GENERATED.has(ep.index)?`<span class="gen-tag" title="Generated">✓</span>`:``)+
    (ep.requiresAuth?`<span class="lock">🔒</span>`:``);
  row.querySelector('input').onclick=e=>{
    e.stopPropagation();
    toggleSel(ep.index,e.target.checked);
    refreshChecks();  // update folder/master boxes in place — no re-render
  };
  row.onclick=()=>openEndpoint(ep.index);
  return row;
}

// Recomputes every folder checkbox and the master checkbox from SELECTED,
// without rebuilding the tree DOM. Called after any in-tree selection change.
function refreshChecks(){
  for(const fbox of $$('.folder-box')){
    let idxs=[];try{idxs=JSON.parse(fbox.dataset.idxs||'[]');}catch(_){}
    syncFolderBox(fbox,idxs);
  }
  updateSel();  // updates count, generate button, and master checkbox
}

// Reflect a folder's selection state on its header checkbox:
// checked = all in folder selected, indeterminate = some, empty = none.
function syncFolderBox(box,idxs){
  const sel=idxs.filter(i=>SELECTED.has(i)).length;
  box.checked=idxs.length>0 && sel===idxs.length;
  box.indeterminate=sel>0 && sel<idxs.length;
}

const SELECTED=new Set();
function toggleSel(idx,on){on?SELECTED.add(idx):SELECTED.delete(idx);updateSel();}
function updateSel(){
  $('#selInfo').textContent=`${SELECTED.size} selected`;
  $('#generate').disabled=SELECTED.size===0;
  syncMaster();
}
// Reflect the visible selection state on the master checkbox:
// checked = all visible selected, indeterminate = some, empty = none.
function syncMaster(){
  const box=$('#selectAllBox');if(!box)return;
  const vis=filtered();
  const sel=vis.filter(ep=>SELECTED.has(ep.index)).length;
  box.checked=vis.length>0 && sel===vis.length;
  box.indeterminate=sel>0 && sel<vis.length;
  $('#selectAllLabel').textContent=box.checked?'Deselect all':'Select all';
}
// master checkbox: toggles all currently-visible (filtered) endpoints, in
// place (preserves expand/collapse + scroll).
$('#selectAllBox').onclick=()=>{
  const vis=filtered();
  const on=!(vis.length>0 && vis.every(ep=>SELECTED.has(ep.index)));
  vis.forEach(ep=>on?SELECTED.add(ep.index):SELECTED.delete(ep.index));
  // sync every visible row checkbox in the DOM
  $$('.ep input').forEach(cb=>{cb.checked=SELECTED.has(+cb.dataset.idx);});
  refreshChecks();
};
// Searching does need a re-render (the visible set changes structurally).
$('#search').oninput=renderTree;

// ---- endpoint detail / request builder ----
// Per-endpoint edit cache so switching endpoints doesn't lose unsaved edits.
const EDITS={};
// Snapshots the current builder form into EDITS[CUR].
function captureEdits(){
  if(CUR==null)return;
  const prev=EDITS[CUR]||{};
  EDITS[CUR]={
    method:$('#mMethod').value, url:$('#mUrl').value,
    params:collectKv('#pane-params'), headers:collectKv('#pane-headers'),
    body:currentBody(), authType:$('#authType').value, authToken:$('#authToken').value,
    authHeaderName:prev.authHeaderName, name:prev.name, description:prev.description,
    output:currentOutput(), defaults:prev.defaults,
  };
}
// Reads the Output tab into a settings record (blank fields omitted).
function currentOutput(){
  const o={};
  const dir=$('#outDir').value.trim(); if(dir)o.outputDir=dir;
  const f=$('#outFile').value.trim(); if(f)o.fileName=f;
  const a=$('#outAction').value.trim(); if(a)o.actionClass=a;
  const r=$('#outResponse').value.trim(); if(r)o.responseClass=r;
  const m=$('#outMode').value; if(m&&m!=='default')o.mode=m;
  return o;
}

async function openEndpoint(idx){
  captureEdits();  // preserve edits on the endpoint we're leaving
  CUR=idx;
  $$('.ep').forEach(e=>e.classList.toggle('active',+e.dataset.idx===idx));
  $('#blank').classList.add('hidden');
  $('#builder').classList.remove('hidden');
  closeDrawer();  // on mobile, reveal the builder after picking

  // Use cached edits only if they're a full snapshot (have request fields);
  // an output-only stub (from "apply to all") still needs a fetch.
  let d=(EDITS[idx]&&EDITS[idx].method)?EDITS[idx]:null;
  const stubOutput=(!d&&EDITS[idx]&&EDITS[idx].output)?EDITS[idx].output:null;
  let isEdit=!!d;
  if(!d){
    // show a loading state while fetching detail
    $('#epName').innerHTML=`${esc(EP_BY_INDEX[idx].name)} <span class="spinner"></span>`;
    $('#epDesc').textContent='';
    let r;
    try{r=await jget('/api/endpoint?index='+idx);}
    catch(e){$('#epName').textContent='Failed to load endpoint';return;}
    if(CUR!==idx)return;  // user moved on while we were loading
    d={method:r.method,url:r.url,params:r.queryParams,headers:r.headers,
       body:{kind:r.body.kind||'none',raw:r.body.raw||'',fields:r.body.fields||[]},
       authType:r.auth.type||'none',authToken:r.auth.token||'',
       authHeaderName:(r.auth&&r.auth.headerName)||null,
       name:r.name,description:r.description,
       output:{...(r.output&&{outputDir:r.output.outputDir,fileName:r.output.fileName,
         actionClass:r.output.actionClass,responseClass:r.output.responseClass,
         mode:r.output.mode==='default'?undefined:r.output.mode}),...(stubOutput||{})},
       defaults:(r.output&&r.output.defaults)||{}};
    EP_BY_INDEX[idx]._detail=d;  // remember name/desc for header
    EDITS[idx]=d;  // promote to a full snapshot
  }
  AUTH_HEADER_NAME=d.authHeaderName||null;
  const meta=EP_BY_INDEX[idx]._detail||d;
  $('#epName').textContent=meta.name||EP_BY_INDEX[idx].name;
  $('#epDesc').textContent=meta.description||'';
  $('#mMethod').value=d.method;
  $('#mUrl').value=d.url;
  renderKv('#pane-params',d.params,'bParams');
  renderKv('#pane-headers',d.headers,'bHeaders');
  // body
  const bk=(d.body&&d.body.kind)||'none';
  $('#bodyKind').value=bk;
  $('#bodyRaw').value=(d.body&&d.body.raw)||'';
  renderBodyFields((d.body&&d.body.fields)||[]);
  syncBodyUI();
  // auth
  $('#authType').value=d.authType||'none';
  $('#authToken').value=d.authToken||'';
  syncAuthUI();
  // output tab — fill values + placeholders from defaults
  const o=d.output||{}, def=(EP_BY_INDEX[idx]._detail&&EP_BY_INDEX[idx]._detail.defaults)||d.defaults||{};
  $('#outDir').value=o.outputDir||''; $('#outDir').placeholder=def.outputDir||'(default)';
  $('#outFile').value=o.fileName||''; $('#outFile').placeholder=def.fileName||'(default)';
  $('#outAction').value=o.actionClass||''; $('#outAction').placeholder=def.actionClass||'(default)';
  $('#outResponse').value=o.responseClass||''; $('#outResponse').placeholder=def.responseClass||'(default)';
  $('#outMode').value=o.mode||'default';
  updateOutHint();
  // reset code/preview lazily
  $('#codeBox').textContent='Select the Code tab to preview…';
  switchTab('params');
  if(isEdit)markDirty();
}
// Live hint showing the effective file path + class names.
function updateOutHint(){
  const idx=CUR; if(idx==null)return;
  const def=(EP_BY_INDEX[idx]&&EP_BY_INDEX[idx]._detail&&EP_BY_INDEX[idx]._detail.defaults)||{};
  const o=currentOutput();
  const dir=o.outputDir||def.outputDir||'';
  const file=o.fileName||def.fileName||'';
  const act=o.actionClass||def.actionClass||'';
  const resp=o.responseClass||def.responseClass||'';
  $('#outHint').innerHTML=
    `Will write → <b>${esc(dir)}/${esc(file)}</b><br>`+
    `Action: <b>${esc(act)}</b> · Response: <b>${esc(resp)}</b>`;
}
// Output fields refresh the hint + mark dirty as the user types.
['#outDir','#outFile','#outAction','#outResponse'].forEach(s=>{
  const el=$(s);if(el)el.addEventListener('input',()=>{updateOutHint();markDirty();});
});
$('#outMode').addEventListener('change',()=>{updateOutHint();markDirty();});
// "apply to all": copy this endpoint's output dir into every endpoint's edits.
$('#outApplyDir').onclick=()=>{
  const dir=$('#outDir').value.trim();
  captureEdits();
  for(const i of Object.keys(EP_BY_INDEX)){
    const e=EDITS[i]||(EDITS[i]={});
    e.output=e.output||{};
    if(dir)e.output.outputDir=dir; else delete e.output.outputDir;
  }
  $('#outApplyDir').textContent='applied ✓';
  setTimeout(()=>{$('#outApplyDir').textContent='apply to all';},1200);
};

// ---- folder picker ----
let PICK_PATH='';
let PICK_REQ=0;  // in-flight token: only the latest navigation renders
async function loadDirs(p){
  const reqId=++PICK_REQ;
  const target=p||'';
  let d;
  try{d=await jget('/api/dirs?path='+encodeURIComponent(target));}
  catch(e){
    if(reqId!==PICK_REQ)return;  // superseded
    $('#pickList').innerHTML=`<div class="pick-empty">Failed to read folders</div>`;
    return;
  }
  if(reqId!==PICK_REQ)return;  // a newer navigation won — drop this render
  const here=d.path||'';        // server-normalized current path (LOCAL, stable)
  PICK_PATH=here;
  renderBreadcrumb(here);
  $('#pickSel').textContent='Selected: '+(here||'(project root)');
  const list=$('#pickList');list.innerHTML='';
  // ".." up a level — shown whenever we're not at the project root.
  if(d.parent!==null){
    const parent=d.parent;  // '' at depth 1 (= root), else the parent path
    const up=document.createElement('div');up.className='pick-item up';
    up.innerHTML=`<span class="ico">↩</span><span>.. (up one level)</span>`;
    up.onclick=()=>loadDirs(parent);
    list.appendChild(up);
  }
  for(const name of d.dirs){
    const it=document.createElement('div');it.className='pick-item';
    it.innerHTML=`<span class="ico">📁</span><span>${esc(name)}</span>`;
    // capture the path of THIS listing (here), not the mutable global
    it.onclick=()=>loadDirs(here?here+'/'+name:name);
    list.appendChild(it);
  }
  if(!d.dirs.length){
    const hint=document.createElement('div');hint.className='pick-empty';
    hint.textContent='No subfolders here. Use this folder, or go up.';
    list.appendChild(hint);
  }
}
// Clickable breadcrumb so the user can jump to any ancestor (incl. root).
function renderBreadcrumb(path){
  const bc=$('#pickPath');bc.innerHTML='';
  const root=document.createElement('span');root.className='crumb';
  root.textContent='⌂ root';root.onclick=()=>loadDirs('');
  bc.appendChild(root);
  let acc='';
  for(const seg of path.split('/').filter(Boolean)){
    bc.appendChild(document.createTextNode(' / '));
    acc=acc?acc+'/'+seg:seg;
    const cur=acc;
    const c=document.createElement('span');c.className='crumb';
    c.textContent=seg;c.onclick=()=>loadDirs(cur);
    bc.appendChild(c);
  }
}
function openPicker(){
  $('#pickOverlay').classList.remove('hidden');
  // start from the current value if it looks project-relative, else root
  const cur=$('#outDir').value.trim();
  loadDirs(cur && !cur.startsWith('/') ? cur : '');
}
function closePicker(){$('#pickOverlay').classList.add('hidden');}
$('#outBrowse').onclick=openPicker;
$('#pickClose').onclick=closePicker;
$('#pickOverlay').onclick=e=>{if(e.target===$('#pickOverlay'))closePicker();};
$('#pickUse').onclick=()=>{
  $('#outDir').value=PICK_PATH;  // '' = project root (intentional)
  closePicker();
  updateOutHint();markDirty();
};
// Esc closes the picker (and swallow it so it doesn't hit other handlers).
document.addEventListener('keydown',e=>{
  if(e.key==='Escape' && !$('#pickOverlay').classList.contains('hidden')){
    e.preventDefault();e.stopPropagation();closePicker();
  }
},true);

// small "edited" indicator next to the endpoint name
function markDirty(){
  if(CUR!=null && !$('#dirtyTag')){
    const t=document.createElement('span');t.id='dirtyTag';t.className='dirty-tag';t.textContent='edited';
    $('#epName').appendChild(t);
  }
}
// any edit in the builder marks the endpoint dirty
['#mMethod','#mUrl','#bodyKind','#bodyRaw','#authType','#authToken'].forEach(s=>{
  const el=$(s);if(el)el.addEventListener('input',markDirty);
});
$('.tabwrap').addEventListener('input',markDirty);

function renderKv(sel,list,badgeId){
  const wrap=$(sel);
  wrap.innerHTML='';
  const t=document.createElement('table');t.className='kv';
  const tb=document.createElement('tbody');t.appendChild(tb);
  (list||[]).forEach(kv=>tb.appendChild(kvRow(kv.key,kv.value)));
  wrap.appendChild(t);
  const add=document.createElement('button');add.className='addrow';add.textContent='+ Add row';
  add.onclick=()=>{tb.appendChild(kvRow('',''));updateBadges();};
  wrap.appendChild(add);
  if(badgeId)updateBadges();
}
function kvRow(k,v){
  const tr=document.createElement('tr');
  tr.innerHTML=`<td><input placeholder="key" value="${esc(k)}"></td>`+
    `<td><input placeholder="value" value="${esc(v)}"></td>`+
    `<td class="del"><button class="icon-btn">✕</button></td>`;
  tr.querySelector('.icon-btn').onclick=()=>{tr.remove();updateBadges();};
  tr.querySelectorAll('input').forEach(i=>i.oninput=updateBadges);
  return tr;
}
function collectKv(sel){
  return $$(`${sel} tr`).map(tr=>{const i=tr.querySelectorAll('input');
    return{key:i[0].value,value:i[1].value};}).filter(x=>x.key.trim());
}
function updateBadges(){
  $('#bParams').textContent=collectKv('#pane-params').length;
  $('#bHeaders').textContent=collectKv('#pane-headers').length;
}

function renderBodyFields(fields){
  const wrap=$('#bodyFields');wrap.innerHTML='';
  const t=document.createElement('table');t.className='kv';const tb=document.createElement('tbody');t.appendChild(tb);
  (fields.length?fields:[{key:'',value:''}]).forEach(f=>tb.appendChild(kvRow(f.key,f.value)));
  wrap.appendChild(t);
  const add=document.createElement('button');add.className='addrow';add.textContent='+ Add field';
  add.onclick=()=>tb.appendChild(kvRow('',''));
  wrap.appendChild(add);
}
function syncBodyUI(){
  const k=$('#bodyKind').value;
  $('#bodyRaw').classList.toggle('hidden',k!=='raw');
  $('#bodyFields').classList.toggle('hidden',!(k==='formdata'||k==='urlencoded'));
}
$('#bodyKind').onchange=syncBodyUI;
function syncAuthUI(){$('#authToken').classList.toggle('hidden',$('#authType').value==='none');}
$('#authType').onchange=syncAuthUI;

// tabs
$$('.tab').forEach(t=>t.onclick=()=>switchTab(t.dataset.pane));
function switchTab(name){
  $$('.tab').forEach(t=>t.classList.toggle('on',t.dataset.pane===name));
  $$('.pane').forEach(p=>p.classList.toggle('on',p.id==='pane-'+name));
  if(name==='code')loadPreview();
}

async function loadPreview(){
  if(CUR==null)return;
  $('#codeFile').textContent='';
  $('#codeBox').textContent='Generating…';
  // include the in-flight Output overrides so the preview reflects edits
  const o=currentOutput();
  const qs=Object.entries(o).map(([k,v])=>`${k}=${encodeURIComponent(v)}`).join('&');
  try{
    const d=await jget('/api/preview?index='+CUR+(qs?'&'+qs:''));
    $('#codeFile').textContent=d.fileName||'';
    $('#codeBox').textContent=d.code||'// (no code)';
  }catch(e){
    $('#codeBox').textContent='// Failed to load preview: '+String(e);
  }
}
$('#copyCode').onclick=()=>navigator.clipboard.writeText($('#codeBox').textContent);

// ---- send (try it) ----
function currentBody(){
  const k=$('#bodyKind').value;
  if(k==='none')return{kind:null};
  if(k==='raw')return{kind:'raw',raw:$('#bodyRaw').value};
  return{kind:k,fields:collectKv('#bodyFields')};
}
let AUTH_HEADER_NAME=null;  // custom apiKey header name from the endpoint detail
function applyAuthHeader(headers){
  const t=$('#authType').value, tok=$('#authToken').value.trim();
  if(t==='none'||!tok)return headers;
  if(t==='bearer')headers.push({key:'Authorization',value:'Bearer '+tok});
  else if(t==='basic')headers.push({key:'Authorization',value:'Basic '+tok});
  else if(t==='apiKey')headers.push({key:AUTH_HEADER_NAME||'X-Api-Key',value:tok});
  return headers;
}
$('#send').onclick=async()=>{
  if(CUR==null)return;
  const btn=$('#send');btn.disabled=true;btn.innerHTML='<span class="spinner"></span>';
  $('#resp').classList.remove('hidden');
  $('#respStatus').innerHTML='';$('#respMeta').textContent='Sending…';
  $('#respBody').innerHTML='<div class="resp-empty">Waiting for response…</div>';
  try{
    const res=await jpost('/api/try',{
      url:$('#mUrl').value,method:$('#mMethod').value,
      headers:applyAuthHeader(collectKv('#pane-headers')),
      queryParams:collectKv('#pane-params'),
      body:currentBody()
    });
    renderResponse(res);
  }catch(e){renderResponse({ok:false,error:String(e)});}
  finally{btn.disabled=false;btn.textContent='Send';}
};
// Pretty-prints + syntax-highlights a JSON string. Falls back to escaped plain
// text when the body isn't valid JSON.
function highlightJson(raw){
  let obj;
  try{obj=JSON.parse(raw);}catch(_){return esc(raw);}
  const json=JSON.stringify(obj,null,2);
  return esc(json).replace(
    /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+\-]?\d+)?)/g,
    m=>{
      let cls='j-num';
      if(/^"/.test(m))cls=/:$/.test(m)?'j-key':'j-str';
      else if(/true|false/.test(m))cls='j-bool';
      else if(/null/.test(m))cls='j-null';
      return `<span class="${cls}">${m}</span>`;
    });
}

function renderResponse(res){
  $('#resp').classList.remove('hidden');
  if(!res.ok){
    $('#respStatus').innerHTML=`<span class="status bad">failed</span>`;
    $('#respMeta').textContent='';
    $('#rhCount').textContent='0';
    $('#respBody').innerHTML=`<div class="resp-empty">${esc(res.error||'Request failed')}</div>`;
    $('#respHeadersPane').innerHTML='';
    switchRespTab('body');
    return;
  }
  const cls=res.status>=200&&res.status<300?'ok':(res.status>=400?'bad':'warn');
  $('#respStatus').innerHTML=`<span class="status ${cls}">${res.status}</span>`;
  const size=res.body?`${(new Blob([res.body]).size/1024).toFixed(1)} KB`:'0 KB';
  $('#respMeta').textContent=`${res.timeMs} ms · ${size}`;

  // Body pane — highlighted JSON (or raw text)
  $('#respBody').innerHTML=`<pre>${highlightJson(res.body||'')}</pre>`;

  // Headers pane — request URL + a clean table of response headers
  const rh=res.responseHeaders||{};
  const hk=Object.keys(rh);
  $('#rhCount').textContent=hk.length;
  let hh=res.requestUrl?`<div class="rh-url"><b>Request URL</b> &nbsp;${esc(res.requestUrl)}</div>`:'';
  hh+=`<table class="rh-table"><tbody>`+
    (hk.length?hk.map(k=>`<tr><td class="k">${esc(k)}</td><td class="v">${esc(rh[k])}</td></tr>`).join('')
      :`<tr><td class="v" colspan="2">No response headers</td></tr>`)+
    `</tbody></table>`;
  $('#respHeadersPane').innerHTML=hh;
  switchRespTab('body');
}

// response sub-tabs (Body / Headers)
function switchRespTab(name){
  $$('.rtab').forEach(t=>t.classList.toggle('on',t.dataset.rt===name));
  $('#respBody').classList.toggle('hidden',name!=='body');
  $('#respHeadersPane').classList.toggle('hidden',name!=='headers');
}
$$('.rtab').forEach(t=>t.onclick=()=>switchRespTab(t.dataset.rt));
$('#respExpand').onclick=()=>$('#resp').classList.toggle('expanded');
$('#respClose').onclick=()=>$('#resp').classList.add('hidden');

// Endpoint key ("<METHOD> <path>") matching the server's ApiEndpoint.key.
function epKey(i){const e=EP_BY_INDEX[i];return e?`${e.method} ${e.path}`:null;}
// Builds the per-endpoint output settings map for selected endpoints.
function buildSettingsPayload(){
  captureEdits();  // flush the currently-open endpoint's Output edits
  const out={};
  for(const i of SELECTED){
    const o=(EDITS[i]&&EDITS[i].output)||{};
    if(Object.keys(o).length){const k=epKey(i);if(k)out[k]=o;}
  }
  return out;
}

// ---- generate selected ----
$('#generate').onclick=async()=>{
  if(!SELECTED.size)return;
  const btn=$('#generate');btn.disabled=true;btn.innerHTML='<span class="spinner"></span> Generating…';
  try{
    const d=await jpost('/api/generate',{selectedIndexes:[...SELECTED],settings:buildSettingsPayload()});
    showGenResults(d);
  }catch(e){showGenResults({error:String(e)});}
  finally{btn.disabled=false;btn.textContent='Generate selected';updateSel();}
};
const GENERATED=new Set();  // endpoint indexes already generated this session
function showGenResults(d){
  const box=$('#genres');box.classList.remove('hidden');
  if(d.error||!Array.isArray(d.generated)){
    box.innerHTML=`<h3>Error<button class="x">✕</button></h3>`+
      `<div class="gr-row"><span class="bad">✗ ${esc(d.error||'Unexpected response')}</span></div>`;
  }else{
    const skipped=d.skipped||[];
    let h=`<h3>Generated ${d.generated.length}`+(skipped.length?`, skipped ${skipped.length}`:``)+`<button class="x">✕</button></h3>`;
    // Auto re-login outcome, when it happened — otherwise the token silently
    // changing mid-run would be invisible.
    if(d.tokenRefreshed)h+=`<div class="gr-row"><span class="ok">↻</span><span>Token refreshed automatically mid-run</span></div>`;
    if(d.authFailed)h+=`<div class="gr-row"><span class="bad">✗</span><span>Auth failed — re-login did not help. Check the saved credentials.</span></div>`;
    for(const g of d.generated)h+=`<div class="gr-row"><span class="ok">✓</span><span>${esc(g.file)}</span></div>`;
    for(const s of skipped)h+=`<div class="gr-row"><span class="bad">✗</span><span>${esc(s.name)}</span><span class="gr-sub">${esc(s.reason)}</span></div>`;
    if(Array.isArray(d.logs)&&d.logs.length)h+=`<details class="gr-logs"><summary>${d.logs.length} log lines</summary><pre>${esc(d.logs.join('\n'))}</pre></details>`;
    box.innerHTML=h;
    // mark the just-generated endpoints in the tree
    [...SELECTED].forEach(i=>GENERATED.add(i));
    $$('.ep').forEach(row=>{
      const i=+row.dataset.idx;
      if(GENERATED.has(i)&&!row.querySelector('.gen-tag')){
        const t=document.createElement('span');t.className='gen-tag';t.textContent='✓';t.title='Generated';
        row.appendChild(t);
      }
    });
  }
  box.querySelector('.x').onclick=()=>box.classList.add('hidden');
  // Keep the chip honest about what just happened to the token.
  if(d.authFailed)renderTokenChip('bad',d.token||'');
  else if(d.tokenRefreshed)renderTokenChip('ok',d.token||'');
}

// ---- auth token chip + modal ----
// The web UI runs in its own isolate with a COPY of the token, so a refresh on
// the terminal side isn't visible here until the next request. The chip makes
// that state legible, and one click fixes a stale token.
function renderTokenChip(state,masked){
  const c=$('#tokChip');if(!c)return;
  c.className='chip tok '+state;
  const label=state==='none'?'none':(masked||'set');
  c.innerHTML=`Token <b>${esc(label)}</b>`;
  c.title=state==='bad'
    ?'Token was rejected — click to re-login'
    :(state==='none'?'No token — click to add one':'Auth token — click to refresh');
}

function openTokenModal(){
  const hasLogin=!!(TREE&&TREE.hasLogin);
  $('#tokHint').textContent=hasLogin
    ?'Auto re-login is configured for this source. Re-login now, or paste a token.'
    :'Auto re-login is not configured. Run `api2dart generate` in the terminal to set it up, or paste a token below.';
  $('#tokRelogin').classList.toggle('hidden',!hasLogin);
  $('#tokOtp').classList.add('hidden');
  $('#tokMsg').textContent='';
  $('#tokPaste').value='';
  $('#tokOverlay').classList.remove('hidden');
  $('#tokPaste').focus();
}
function closeTokenModal(){$('#tokOverlay').classList.add('hidden');}

async function postRelogin(payload,btn){
  const msg=$('#tokMsg');
  const original=btn?btn.textContent:'';
  if(btn){btn.disabled=true;btn.innerHTML='<span class="spinner"></span> Working…';}
  try{
    const d=await jpost('/api/relogin',payload);
    if(d.ok){
      renderTokenChip('ok',d.token||'');
      if(TREE)TREE.hasToken=true;
      msg.textContent='✓ Token updated.';
      setTimeout(closeTokenModal,700);
    }else{
      msg.textContent='✗ '+(d.error||'Could not refresh the token.');
      renderTokenChip('bad','');
    }
  }catch(e){msg.textContent='✗ '+String(e);}
  finally{if(btn){btn.disabled=false;btn.textContent=original;}}
}

$('#tokClose').onclick=closeTokenModal;
$('#tokOverlay').onclick=e=>{if(e.target===$('#tokOverlay'))closeTokenModal();};
$('#tokRelogin').onclick=()=>{
  const otp=$('#tokOtp').value.trim();
  postRelogin(otp?{otp}:{},$('#tokRelogin'));
};
$('#tokUse').onclick=()=>{
  const t=$('#tokPaste').value.trim();
  if(!t){$('#tokMsg').textContent='Paste a token first.';return;}
  postRelogin({token:t},$('#tokUse'));
};
$('#tokPaste').addEventListener('keydown',e=>{if(e.key==='Enter')$('#tokUse').click();});

// keyboard: "/" focuses search, Ctrl/Cmd+Enter sends the current request
document.addEventListener('keydown',e=>{
  const tag=document.activeElement.tagName;
  if(e.key==='/' && tag!=='INPUT' && tag!=='TEXTAREA' && tag!=='SELECT'){
    e.preventDefault();$('#search').focus();
  }
  if((e.metaKey||e.ctrlKey) && e.key==='Enter' && CUR!=null){e.preventDefault();$('#send').click();}
});

// ---- mobile sidebar drawer ----
function openDrawer(){$('.side').classList.add('open');$('#sideOverlay').classList.add('open');}
function closeDrawer(){$('.side').classList.remove('open');$('#sideOverlay').classList.remove('open');}
$('#menuToggle').onclick=()=>$('.side').classList.contains('open')?closeDrawer():openDrawer();
$('#sideOverlay').onclick=closeDrawer;

load().catch(e=>{$('#tree').innerHTML=`<div class="empty">Failed to load: ${esc(String(e))}</div>`;});
</script>
</body>
</html>''';
