# frozen_string_literal: true

require "json"

module MissionControlDashboard
  # Renders the whole dashboard as one self-contained HTML document.
  # No CDN, no build step, no framework: the board JSON is embedded in the
  # page and the browser draws from it, then polls /api/board to stay live.
  module View
    module_function

    def render(payload)
      json = JSON.generate(payload).gsub("<") { "\\u003c" }
      PAGE.sub("__BOARD_JSON__") { json }
    end

    def error_page(message)
      body = message.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      <<~HTML
        <!doctype html><html><head><meta charset="utf-8">
        <title>Mission Control - board error</title>
        <style>
          body{background:#0a0e15;color:#e8eefb;font:15px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;padding:48px}
          .box{max-width:760px;margin:0 auto;background:#121926;border:1px solid #ff6b6b40;border-left:4px solid #ff6b6b;border-radius:12px;padding:28px}
          h1{margin:0 0 12px;font-size:18px;color:#ff6b6b;letter-spacing:.04em;text-transform:uppercase}
          pre{white-space:pre-wrap;color:#ffb4b4;background:#0a0e15;padding:16px;border-radius:8px;margin:16px 0}
          p{color:#8a99b0}
        </style></head><body><div class="box">
        <h1>Board failed to load</h1><pre>#{body}</pre>
        <p>Fix the YAML and refresh this page. The server keeps running.</p>
        </div></body></html>
      HTML
    end

    PAGE = <<~'HTML'
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Mission Control</title>
      <style>
        *{box-sizing:border-box}
        :root{
          --bg:#0a0e15; --panel:#121926; --panel2:#0d131d; --line:#1e2836;
          --text:#e8eefb; --dim:#8a99b0; --faint:#5d6b80;
          --done:#2dd4a7; --live:#5b9df9; --todo:#7b8aa3; --blocked:#f5a524; --overdue:#ff6b6b;
          --accent:#5b9df9; --name-w:216px;
        }
        html,body{margin:0;background:var(--bg);color:var(--text)}
        body{font:14px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
             padding:20px;max-width:1560px;margin:0 auto;-webkit-font-smoothing:antialiased}
        .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-variant-numeric:tabular-nums}

        header{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;flex-wrap:wrap;margin-bottom:18px}
        h1{margin:0;font-size:21px;letter-spacing:-.01em;font-weight:650}
        .sub{color:var(--faint);font-size:12px;margin-top:3px}
        .dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--done);margin-right:7px;
             box-shadow:0 0 0 3px #2dd4a725;animation:pulse 2.6s ease-in-out infinite;vertical-align:middle}
        @keyframes pulse{50%{opacity:.35}}
        .clock{font-size:13px;color:var(--dim);text-align:right}
        .clock b{display:block;font-size:22px;color:var(--text);font-weight:600;letter-spacing:.02em}

        .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(228px,1fr));gap:12px;margin-bottom:16px}
        .tile{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:15px 17px;position:relative;overflow:hidden}
        .tile .k{font-size:10.5px;letter-spacing:.13em;text-transform:uppercase;color:var(--faint);font-weight:600}
        .tile .v{font-size:27px;font-weight:650;margin-top:7px;letter-spacing:-.02em}
        .tile .n{font-size:12px;color:var(--dim);margin-top:5px;line-height:1.45}
        .tile.risk{border-color:#ff6b6b55;background:linear-gradient(180deg,#ff6b6b0e,transparent 60%),var(--panel)}
        .tile.ok{border-color:#2dd4a740}
        .meter{height:6px;border-radius:99px;background:#ffffff10;margin-top:11px;overflow:hidden}
        .meter i{display:block;height:100%;border-radius:99px;transition:width .5s ease}

        .card{background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden;margin-bottom:16px}
        .card-head{display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;
                   padding:13px 17px;border-bottom:1px solid var(--line);background:var(--panel2)}
        .card-head h2{margin:0;font-size:12px;letter-spacing:.13em;text-transform:uppercase;color:var(--dim);font-weight:600}
        .ctrls{display:flex;align-items:center;gap:9px;flex-wrap:wrap}
        button{background:#1b2433;color:var(--text);border:1px solid var(--line);border-radius:8px;
               padding:6px 11px;font-size:12px;cursor:pointer;font-family:inherit;transition:.15s}
        button:hover{background:#25314a;border-color:#31405a}
        button.on{background:var(--accent);border-color:var(--accent);color:#04101f;font-weight:600}
        .wk{color:var(--dim);font-size:12px;min-width:112px;text-align:center}
        input[type=range]{width:104px;accent-color:var(--accent)}
        .legend{display:flex;gap:13px;flex-wrap:wrap;font-size:11.5px;color:var(--dim)}
        .legend i{display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:5px;vertical-align:baseline}

        .scroll{overflow-x:auto;overflow-y:hidden}
        .content{position:relative;min-width:100%}
        .ruler{display:flex;height:44px;border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5;background:var(--panel)}
        .corner{width:var(--name-w);flex:none;position:sticky;left:0;z-index:6;background:var(--panel);
                border-right:1px solid var(--line);display:flex;align-items:center;padding:0 14px;
                font-size:10.5px;letter-spacing:.11em;text-transform:uppercase;color:var(--faint);font-weight:600}
        .rtrack{position:relative;flex:none;height:44px}
        .dayhdr{position:absolute;top:0;height:44px;border-left:1px solid var(--line);padding:5px 0 0 8px;overflow:hidden}
        .dayhdr b{font-size:12px;font-weight:600;display:block;line-height:1.25}
        .dayhdr span{font-size:10.5px;color:var(--faint)}
        .dayhdr.today b{color:var(--accent)}
        .dayhdr.wknd{background:#ffffff05}
        .tick{position:absolute;bottom:3px;font-size:9.5px;color:var(--faint);transform:translateX(-50%);white-space:nowrap}

        .rows{position:relative}
        .row{display:flex;height:34px;border-bottom:1px solid #ffffff08}
        .row:hover .lane{background:#ffffff05}
        .rname{width:var(--name-w);flex:none;position:sticky;left:0;z-index:4;background:var(--panel);
               border-right:1px solid var(--line);display:flex;align-items:center;gap:8px;padding:0 12px;
               font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .row:hover .rname{background:#151d2b}
        .rname s{width:3px;height:15px;border-radius:2px;flex:none;text-decoration:none}
        .rname em{font-style:normal;overflow:hidden;text-overflow:ellipsis}
        .lane{position:relative;flex:none;height:34px}
        .trow{height:29px;background:var(--panel2)}
        .trow .rname{background:var(--panel2);font-size:10.5px;letter-spacing:.12em;text-transform:uppercase;
                     color:var(--dim);font-weight:600}
        .trow .lane{height:29px;background:var(--panel2)}
        .gl{position:absolute;top:0;bottom:0;width:1px;background:var(--line)}
        .gl.h{background:#ffffff07}
        .wkndband{position:absolute;top:0;bottom:0;background:#ffffff04}

        .bar{position:absolute;top:6px;height:22px;border-radius:6px;display:flex;align-items:center;
             gap:4px;padding:0 6px;font-size:11.5px;white-space:nowrap;overflow:hidden;cursor:default;
             border:1px solid transparent;transition:filter .15s}
        .bar:hover{filter:brightness(1.22);z-index:3}
        .bar .g{flex:none;font-size:10px;opacity:.9}
        .bar .t{overflow:hidden;text-overflow:ellipsis}
        .bar .fill{position:absolute;left:0;top:0;bottom:0;background:#ffffff28;pointer-events:none;border-radius:5px 0 0 5px}
        .bar.done{background:#2dd4a726;border-color:#2dd4a766;color:#8ff0d6}
        .bar.live{background:#5b9df930;border-color:var(--live);color:#cfe2ff;box-shadow:0 0 0 1px #5b9df940,0 4px 14px -6px #5b9df9}
        .bar.todo{background:#7b8aa322;border-color:#7b8aa355;color:#c3cede}
        .bar.blocked{background:#f5a52424;border-color:#f5a52470;color:#ffd899}
        .bar.overdue{background:#ff6b6b26;border-color:#ff6b6b80;color:#ffb9b9}
        .bar .t{font-size:10.5px;opacity:.9}
        .bar.tiny{padding:0 3px;justify-content:center}
        .bar.tiny .t{display:none}
        /* scheduled outside the drawn working window: hatched so a squashed
           bar reads as "there is more here" rather than as a rendering glitch */
        .bar.clip{background-image:repeating-linear-gradient(115deg,#ffffff00 0 4px,#ffffff26 4px 8px);
                  border-style:dashed;min-width:10px}
        .bar.clip .g{display:none}
        /* a window the work lives in, not a solid block of booked hours -
           drawn hollow so a Mon->Fri project doesn't read as 40 hours */
        .bar.span{background-color:transparent!important;border-style:dashed;opacity:.92}
        .bar.span::before,.bar.span::after{content:'';position:absolute;top:-1px;bottom:-1px;width:3px;
                                           background:currentColor;opacity:.55;border-radius:2px}
        .bar.span::before{left:-1px} .bar.span::after{right:-1px}

        .nowline{position:absolute;top:0;width:2px;background:var(--overdue);z-index:5;pointer-events:none;
                 box-shadow:0 0 12px 1px #ff6b6b70}
        .nowline b{position:absolute;top:5px;left:-20px;font-size:9px;letter-spacing:.09em;background:var(--overdue);
                   color:#2a0505;padding:2px 5px;border-radius:4px;font-weight:700}

        .lower{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:16px;align-items:start}
        .list{padding:6px 0 10px}
        .item{display:flex;gap:11px;padding:11px 17px;border-bottom:1px solid #ffffff08}
        .item:last-child{border-bottom:none}
        .item s{width:3px;border-radius:2px;flex:none;text-decoration:none}
        .item .b{flex:1;min-width:0}
        .item .ttl{font-size:13.5px;font-weight:550;display:flex;justify-content:space-between;gap:10px}
        .item .ttl span{color:var(--dim);font-size:11.5px;font-weight:400;white-space:nowrap;flex:none}
        .item .mt{font-size:11.5px;color:var(--faint);margin-top:3px}
        .item .note{font-size:11.5px;color:var(--blocked);margin-top:4px}
        .item .meter{margin-top:8px;height:4px}
        .chk{margin-top:7px;display:flex;flex-wrap:wrap;gap:4px 12px;align-items:center;font-size:11.5px}
        .chk span{white-space:nowrap}
        .chk .n{color:var(--faint)}
        .chk .y{color:var(--done);text-decoration:line-through;text-decoration-color:#2dd4a760}
        .chk b{color:var(--dim);font-size:10.5px;font-family:ui-monospace,Menlo,monospace;margin-left:auto}
        .empty{padding:24px 17px;color:var(--faint);font-size:13px;text-align:center}

        .offline{background:#ff6b6b12;border:1px solid #ff6b6b55;border-radius:12px;
                 padding:13px 17px;margin-bottom:16px;font-size:12.5px;color:#ffc9c9;line-height:1.6}
        .offline b{color:var(--overdue)}
        .offline .q{color:var(--dim);font-size:11.5px}
        .warn{background:#f5a5240f;border:1px solid #f5a52440;border-radius:12px;padding:13px 17px;margin-bottom:16px;font-size:12.5px}
        .warn b{color:var(--blocked);display:block;margin-bottom:6px;font-size:11px;letter-spacing:.1em;text-transform:uppercase}
        .warn ul{margin:0;padding-left:18px;color:#e2cfa8}
        footer{color:var(--faint);font-size:11.5px;text-align:center;padding:18px 0 4px;line-height:1.8}
        footer code{color:var(--dim);background:#ffffff0a;padding:2px 6px;border-radius:5px}

        /* ---------- editor ---------- */
        button.primary{background:var(--accent);border-color:var(--accent);color:#04101f;font-weight:600}
        button.primary:hover{background:#7db0ff;border-color:#7db0ff}
        button.danger{color:var(--overdue);border-color:#ff6b6b40}
        button.danger:hover{background:#ff6b6b1a;border-color:var(--overdue)}
        .editable .bar,.editable .item{cursor:pointer}
        .editable .rname em{cursor:pointer}
        .editable .rname em:hover{color:var(--accent);text-decoration:underline dotted}
        .chk span{cursor:default}
        .editable .chk span{cursor:pointer}
        .editable .chk span:hover{color:var(--accent)}
        .ro{font-size:10.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--blocked);
            border:1px solid #f5a52440;border-radius:6px;padding:3px 8px}

        .scrim{position:fixed;inset:0;background:#04070cd9;backdrop-filter:blur(3px);z-index:50;
               display:flex;align-items:flex-start;justify-content:center;padding:40px 16px;overflow-y:auto}
        .modal{background:var(--panel);border:1px solid var(--line);border-radius:16px;width:100%;
               max-width:620px;box-shadow:0 24px 64px -12px #000000cc}
        .modal h3{margin:0;font-size:14px;font-weight:600}
        .mhead{display:flex;align-items:center;justify-content:space-between;gap:12px;
               padding:16px 20px;border-bottom:1px solid var(--line)}
        .mbody{padding:18px 20px;display:grid;grid-template-columns:1fr 1fr;gap:14px}
        .mfoot{display:flex;gap:10px;padding:15px 20px;border-top:1px solid var(--line);align-items:center}
        .mfoot .sp{margin-left:auto}
        .f{display:flex;flex-direction:column;gap:6px}
        .f.wide{grid-column:1/-1}
        .f label{font-size:10.5px;letter-spacing:.11em;text-transform:uppercase;color:var(--faint);font-weight:600}
        .f .hint{font-size:11px;color:var(--faint);line-height:1.45}
        .f input,.f select,.f textarea{background:var(--panel2);border:1px solid var(--line);border-radius:9px;
              color:var(--text);padding:9px 11px;font:13px/1.4 inherit;font-family:inherit;width:100%}
        .f input:focus,.f select:focus,.f textarea:focus{outline:none;border-color:var(--accent);
              box-shadow:0 0 0 3px #5b9df926}
        .f textarea{resize:vertical;min-height:62px}
        .f input.bad{border-color:var(--overdue)}
        .cl-row{display:flex;align-items:center;gap:8px;margin-bottom:6px}
        .cl-row input[type=text]{flex:1}
        .cl-row input[type=checkbox]{width:16px;height:16px;accent-color:var(--done);flex:none;cursor:pointer}
        .cl-row button{padding:5px 9px;line-height:1}
        .err{grid-column:1/-1;background:#ff6b6b14;border:1px solid #ff6b6b45;border-radius:9px;
             padding:10px 13px;font-size:12.5px;color:#ffb9b9;display:none}
        .err.on{display:block}

        .toast{position:fixed;left:50%;bottom:26px;transform:translateX(-50%) translateY(20px);
               background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:12px 18px;
               font-size:13px;box-shadow:0 14px 40px -10px #000;z-index:60;opacity:0;
               transition:opacity .2s,transform .2s;pointer-events:none;max-width:min(560px,92vw)}
        .toast.on{opacity:1;transform:translateX(-50%) translateY(0);pointer-events:auto}
        .toast.ok{border-color:#2dd4a755} .toast.bad{border-color:#ff6b6b66;color:#ffc9c9}
        .toast b{display:block;margin-bottom:3px}
        .toast button{margin-top:9px}

        @media(max-width:640px){body{padding:12px}:root{--name-w:150px}.clock b{font-size:18px}
              .mbody{grid-template-columns:1fr}}
      </style>
      </head>
      <body>
        <header>
          <div>
            <h1><span class="dot"></span><span id="title">Mission Control</span></h1>
            <div class="sub" id="sub"></div>
          </div>
          <div class="clock"><b class="mono" id="clock">--:--:--</b><span id="today"></span></div>
        </header>

        <div class="offline" id="offline" style="display:none"></div>
        <div id="warnbox"></div>
        <div class="tiles" id="tiles"></div>

        <div class="card">
          <div class="card-head">
            <h2>Week Timeline</h2>
            <div class="ctrls">
              <button id="add" class="primary">+ Add task</button>
              <span id="romark" class="ro" style="display:none">read-only</span>
              <span style="width:4px"></span>
              <button id="wk-prev" title="Previous week">&larr;</button>
              <span class="wk mono" id="wklabel"></span>
              <button id="wk-next" title="Next week">&rarr;</button>
              <button id="today-btn">Today</button>
              <span style="width:8px"></span>
              <input type="range" id="zoom" min="6" max="42" step="2" value="18" title="Zoom">
              <button id="compress" title="Compress each day to its working window">Work hours</button>
              <button id="alldays" title="Show weekends even when nothing is booked">7 days</button>
            </div>
            <div class="legend">
              <span><i style="background:#5b9df9"></i>Live</span>
              <span><i style="background:#2dd4a7"></i>Done</span>
              <span><i style="background:#7b8aa3"></i>Scheduled</span>
              <span><i style="background:#f5a524"></i>Blocked</span>
              <span><i style="background:#ff6b6b"></i>Overdue</span>
            </div>
          </div>
          <div class="scroll" id="scroll">
            <div class="content" id="content">
              <div class="ruler"><div class="corner">Track / Task</div><div class="rtrack" id="rtrack"></div></div>
              <div class="rows" id="rows"></div>
              <div class="nowline" id="nowline" style="display:none"><b>NOW</b></div>
            </div>
          </div>
        </div>

        <div class="lower">
          <div class="card">
            <div class="card-head"><h2>Now &amp; Flagged</h2><span class="wk mono" id="livecount"></span></div>
            <div class="list" id="live"></div>
          </div>
          <div class="card">
            <div class="card-head"><h2>Up Next</h2><span class="wk mono" id="nextcount"></span></div>
            <div class="list" id="nextlist"></div>
          </div>
        </div>

        <footer>
          Editing <code id="bpath"></code> and refreshing is the whole workflow.<br>
          <span id="ver"></span>
        </footer>

        <div class="scrim" id="scrim" style="display:none">
          <div class="modal" role="dialog" aria-modal="true">
            <div class="mhead"><h3 id="mtitle">Edit task</h3><button id="mclose">Esc</button></div>
            <div class="mbody">
              <div class="err" id="merr"></div>

              <div class="f wide"><label for="f-title">Title</label>
                <input id="f-title" type="text" placeholder="Mixdown - Podcast Ep.14" autocomplete="off"></div>

              <div class="f"><label for="f-track">Track</label>
                <input id="f-track" type="text" list="tracklist" placeholder="Studio" autocomplete="off">
                <datalist id="tracklist"></datalist></div>

              <div class="f"><label for="f-status">Status</label>
                <select id="f-status">
                  <option value="todo">Scheduled</option>
                  <option value="in_progress">In progress</option>
                  <option value="blocked">Blocked</option>
                  <option value="done">Done</option>
                </select></div>

              <div class="f"><label for="f-start">Start</label>
                <input id="f-start" type="text" placeholder="mon 09:00" autocomplete="off">
                <span class="hint">"mon 09:00", "today 14:00", or "2026-08-14 17:00"</span></div>

              <div class="f"><label for="f-end">End <span style="text-transform:none;letter-spacing:0">(or use duration)</span></label>
                <input id="f-end" type="text" placeholder="tue 18:00" autocomplete="off"></div>

              <div class="f"><label for="f-duration">Duration (hours)</label>
                <input id="f-duration" type="number" min="0.25" step="0.25" placeholder="4">
                <span class="hint">Ignored if you set an End.</span></div>

              <div class="f"><label for="f-effort">Effort (hours)</label>
                <input id="f-effort" type="number" min="0.25" step="0.5" placeholder="leave blank">
                <span class="hint">Real hours of work. Set this when the span is a window, not solid booked time — it is what capacity counts.</span></div>

              <div class="f"><label for="f-owner">Owner</label>
                <input id="f-owner" type="text" autocomplete="off"></div>

              <div class="f"><label for="f-progress">Progress <span id="f-progress-v" class="mono" style="color:var(--dim)">0%</span></label>
                <input id="f-progress" type="range" min="0" max="100" step="5" style="padding:0">
                <span class="hint" id="f-progress-hint">&nbsp;</span></div>

              <div class="f wide"><label>Checklist</label>
                <div id="f-checklist"></div>
                <div><button id="f-additem">+ Add item</button></div>
                <span class="hint">Ticked items set progress automatically unless you move the slider.</span></div>

              <div class="f wide"><label for="f-notes">Notes</label>
                <textarea id="f-notes" placeholder="What is blocking this, what is left, who owes you what."></textarea></div>
            </div>
            <div class="mfoot">
              <button id="f-delete" class="danger">Delete</button>
              <span class="sp"></span>
              <button id="f-cancel">Cancel</button>
              <button id="f-save" class="primary">Save to YAML</button>
            </div>
          </div>
        </div>

        <div class="toast" id="toast"></div>

      <script id="board-data" type="application/json">__BOARD_JSON__</script>
      <script>
      (function(){
        "use strict";
        var B = JSON.parse(document.getElementById('board-data').textContent);
        var S = { px: 18, compress: true, allDays: false, scrolled: false };
        var DAYS = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
        var MON = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        var $ = function(id){ return document.getElementById(id); };

        function esc(s){ return String(s==null?'':s).replace(/[&<>"]/g, function(c){
          return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
        function ms(iso){ return Date.parse(iso); }
        function pad(n){ return n<10?'0'+n:''+n; }
        function hhmm(d){ return pad(d.getHours())+':'+pad(d.getMinutes()); }
        function hrs(h){ return (Math.round(h*10)/10) + 'h'; }

        function dur(sec){
          var neg = sec < 0; sec = Math.abs(Math.round(sec));
          var d = Math.floor(sec/86400), h = Math.floor(sec%86400/3600),
              m = Math.floor(sec%3600/60), s = sec%60, out;
          if (d > 0) out = d+'d '+pad(h)+'h '+pad(m)+'m';
          else out = pad(h)+':'+pad(m)+':'+pad(s);
          return (neg?'-':'') + out;
        }

        /* ---- time scale: maps a moment to an x offset, optionally
               compressing each day down to its working window ---- */
        // Weekend columns only earn their width if something is booked on
        // them (or you asked to see the whole week).
        function visibleDays(){
          var w0 = ms(B.meta.week_start), busy = {}, out = [];
          B.tasks.forEach(function(t){
            var d0 = Math.floor((t.start_ms - w0)/86400000);
            var d1 = Math.floor((t.end_ms - w0)/86400000);
            if (d0 >= 0 && d0 < 7) busy[d0] = true;
            if (d1 >= 0 && d1 < 7) busy[d1] = true;
          });
          var nowD = Math.floor((Date.now() - w0)/86400000);
          for (var d = 0; d < 7; d++){
            if (d >= 5 && !S.allDays && !busy[d] && d !== nowD) continue;
            out.push(d);
          }
          return out;
        }

        // Default zoom fits the visible week to the panel instead of
        // guessing a pixel constant that is wrong on every other screen.
        function fitZoom(){
          var days = visibleDays().length || 5;
          var hoursPerDay = ((S.compress ? B.meta.day_end : 1440)
                           - (S.compress ? B.meta.day_start : 0)) / 60;
          var avail = ($('scroll').clientWidth || 1100) - 224;
          var px = avail / (days * hoursPerDay);
          return Math.max(8, Math.min(26, Math.round(px)));
        }

        function scale(){
          var w0 = ms(B.meta.week_start), segs = [], x = 0;
          var a = S.compress ? B.meta.day_start : 0;
          var b = S.compress ? B.meta.day_end : 1440;

          visibleDays().forEach(function(d){
            var base = w0 + d*86400000;
            var t0 = base + a*60000, t1 = base + b*60000;
            var wpx = (t1-t0)/3600000*S.px;
            segs.push({d:d, t0:t0, t1:t1, x0:x, w:wpx, date:new Date(base)});
            x += wpx;
          });
          return {segs:segs, total:x, a:a, b:b,
            x: function(t){
              if (t <= segs[0].t0) return 0;
              for (var i=0;i<segs.length;i++){
                var s = segs[i];
                if (t < s.t0) return s.x0;
                if (t <= s.t1) return s.x0 + (t-s.t0)/3600000*S.px;
              }
              return x;
            },
            inside: function(t){ return segs.length > 0 && t >= segs[0].t0 && t <= segs[segs.length-1].t1; }
          };
        }

        function tickStep(){
          var opts = [1,2,3,4,6,12];
          for (var i=0;i<opts.length;i++){ if (opts[i]*S.px >= 46) return opts[i]; }
          return 24;
        }

        function drawRuler(sc){
          var r = $('rtrack'), h = '';
          r.style.width = sc.total+'px';
          var todayKey = new Date().toDateString();
          var step = tickStep();
          sc.segs.forEach(function(s){
            var isToday = s.date.toDateString() === todayKey;
            var wknd = s.d >= 5;
            h += '<div class="dayhdr'+(isToday?' today':'')+(wknd?' wknd':'')+'" style="left:'+s.x0+'px;width:'+s.w+'px">'
               + '<b>'+DAYS[s.d]+' '+s.date.getDate()+' '+MON[s.date.getMonth()]+(isToday?' &middot; today':'')+'</b></div>';
            for (var m = sc.a; m <= sc.b; m += step*60){
              if (m === sc.a) continue;
              var tx = s.x0 + (m - sc.a)/60*S.px;
              if (tx > s.x0 + s.w - 6) continue;
              h += '<div class="tick" style="left:'+tx+'px">'+pad(Math.floor(m/60))+':'+pad(m%60)+'</div>';
            }
          });
          r.innerHTML = h;
        }

        function gridHTML(sc){
          var h = '', step = tickStep();
          sc.segs.forEach(function(s){
            if (s.d >= 5) h += '<div class="wkndband" style="left:'+s.x0+'px;width:'+s.w+'px"></div>';
            h += '<div class="gl" style="left:'+s.x0+'px"></div>';
            for (var m = sc.a + step*60; m < sc.b; m += step*60){
              h += '<div class="gl h" style="left:'+(s.x0+(m-sc.a)/60*S.px)+'px"></div>';
            }
          });
          return h;
        }

        var GLYPH = {done:'&#10003;', live:'&#9654;', blocked:'&#9208;', overdue:'!', upcoming:''};

        function drawRows(sc){
          var rows = $('rows'), grid = gridHTML(sc), h = '';
          $('content').style.width = 'calc(var(--name-w) + '+sc.total+'px)';

          B.tracks.forEach(function(track){
            var list = B.tasks.filter(function(t){ return t.track === track; })
                              .sort(function(a,b){ return a.start_ms - b.start_ms; });
            var open = list.filter(function(t){ return t.status !== 'done'; }).length;
            h += '<div class="row trow"><div class="rname">'+esc(track)+'</div>'
               + '<div class="lane" style="width:'+sc.total+'px">'+grid+'</div></div>';

            list.forEach(function(t){
              var x1 = sc.x(t.start_ms), x2 = sc.x(t.end_ms), w = Math.max(x2-x1, 10);
              var clip = S.compress && t.clipped;
              var st = t.state;
              var col = {done:'#2dd4a7', live:'#5b9df9', blocked:'#f5a524', overdue:'#ff6b6b', upcoming:'#7b8aa3'}[st];
              var cls = st === 'upcoming' ? 'todo' : st;
              var s0 = new Date(t.start_ms), s1 = new Date(t.end_ms);
              // The task name is already in the sticky column to the left, so
              // the bar spends its pixels on something new: the time window,
              // then the duration, then nothing but the status glyph.
              var headline = t.spanning ? hrs(t.effort)+' of work' : hhmm(s0)+'-'+hhmm(s1);
              var label = w >= 126 ? headline
                        : w >= 78  ? (t.spanning ? hrs(t.effort) : hhmm(s0))
                        : w >= 56  ? hrs(t.effort) : '';
              var tip = t.title+'\n'+DAYS[(s0.getDay()+6)%7]+' '+hhmm(s0)
                      + ' → '+DAYS[(s1.getDay()+6)%7]+' '+hhmm(s1)
                      + '\n'+(t.spanning
                          ? hrs(t.effort)+' of work inside a '+hrs(t.hours)+' window'
                          : hrs(t.hours))
                      + '\n'+st.toUpperCase()
                      + (t.progress>0 && st!=='done' ? ' - '+Math.round(t.progress*100)+'% done' : '')
                      + (t.checklist && t.checklist.length
                          ? '\n\n'+t.checklist.map(function(c){
                              return (c.done?'[x] ':'[ ] ')+c.title; }).join('\n') : '')
                      + (t.owner ? '\nOwner: '+t.owner : '')
                      + (t.notes ? '\n'+t.notes : '')
                      + (clip ? '\n\nFalls outside your working-hours window - click "Work hours" to see it in full.' : '');
              h += '<div class="row"><div class="rname"><s style="background:'+col+'"></s>'
                 + '<em data-edit="'+esc(t.id)+'">'+esc(t.title)+'</em></div>'
                 + '<div class="lane" style="width:'+sc.total+'px">'+grid
                 + '<div class="bar '+cls+(label&&!clip?'':' tiny')+(clip?' clip':'')+(t.spanning?' span':'')
                 + '" style="left:'+x1+'px;width:'+w+'px" data-edit="'+esc(t.id)+'" title="'+esc(tip)+'">'
                 + (t.progress>0 && t.status!=='done' ? '<div class="fill" style="width:'+(t.progress*100)+'%"></div>' : '')
                 + '<span class="g">'+GLYPH[st]+'</span><span class="t mono">'+label+'</span></div>'
                 + '</div></div>';
            });

            if (!list.length){
              h += '<div class="row"><div class="rname" style="color:var(--faint)">no tasks</div>'
                 + '<div class="lane" style="width:'+sc.total+'px">'+grid+'</div></div>';
            }
            void open;
          });

          if (!B.tasks.length){
            h = '<div class="empty">No tasks on the board yet. Add some to <code>'+esc(B.meta.board_path)+'</code>.</div>';
          }
          rows.innerHTML = h;
        }

        function drawNow(sc){
          var el = $('nowline'), now = Date.now();
          if (B.meta.week_offset !== 0 || !sc.inside(now)){ el.style.display = 'none'; return; }
          el.style.display = 'block';
          el.style.left = 'calc(var(--name-w) + '+sc.x(now)+'px)';
          el.style.height = $('content').offsetHeight + 'px';
        }

        function tiles(){
          var g = B.goal, st = B.stats, h = '';
          if (g.set){
            var left = (ms(g.due) - Date.now())/1000;
            h += '<div class="tile '+(g.passed?'risk':'')+'">'
               + '<div class="k">Pending goal</div>'
               + '<div class="v mono" id="cd">'+dur(left)+'</div>'
               + '<div class="n"><b style="color:var(--text);font-weight:550">'+esc(g.label)+'</b><br>'
               + (g.passed ? 'Due date passed &middot; ' : 'Due ')
               + new Date(ms(g.due)).toLocaleString(undefined,{weekday:'short',hour:'2-digit',minute:'2-digit'})
               + '</div></div>';

            var loadPct = g.capacity > 0 ? Math.min(g.work_left/g.capacity, 1.6)*100/1.6 : 100;
            h += '<div class="tile '+(g.at_risk?'risk':'ok')+'">'
               + '<div class="k">Capacity to goal</div>'
               + '<div class="v mono">'+hrs(g.work_left)+' <span style="font-size:15px;color:var(--faint)">/ '+hrs(g.capacity)+'</span></div>'
               + '<div class="n">'+(g.at_risk
                   ? 'Overcommitted by <b style="color:var(--overdue)">'+hrs(-g.slack)+'</b>. Cut or move something.'
                   : '<b style="color:var(--done)">'+hrs(g.slack)+'</b> of slack in working hours.')
               + '</div><div class="meter"><i style="width:'+loadPct+'%;background:'+(g.at_risk?'var(--overdue)':'var(--done)')+'"></i></div></div>';
          } else {
            h += '<div class="tile"><div class="k">Pending goal</div><div class="v">Not set</div>'
               + '<div class="n">Add a <code>goal:</code> block with <code>label</code> and <code>due</code> to your board.</div></div>';
          }

          var pct = st.total ? Math.round(st.done/st.total*100) : 0;
          h += '<div class="tile"><div class="k">Tasks complete</div>'
             + '<div class="v mono">'+st.done+' <span style="font-size:15px;color:var(--faint)">/ '+st.total+'</span></div>'
             + '<div class="n">'+pct+'% of the week&rsquo;s slate &middot; '+hrs(st.hours_booked)+' booked</div>'
             + '<div class="meter"><i style="width:'+pct+'%;background:var(--done)"></i></div></div>';

          var flag = st.blocked + st.overdue;
          h += '<div class="tile '+(flag?'risk':'')+'"><div class="k">Attention</div>'
             + '<div class="v mono">'+flag+'</div>'
             + '<div class="n">'+st.blocked+' blocked &middot; '+st.overdue+' past due &middot; '+st.live+' running now</div></div>';

          $('tiles').innerHTML = h;
        }

        function itemHTML(t, mode){
          var col = {done:'#2dd4a7', live:'#5b9df9', blocked:'#f5a524', overdue:'#ff6b6b', upcoming:'#7b8aa3'}[t.state];
          var s = new Date(t.start_ms), e = new Date(t.end_ms), now = Date.now();
          var day = DAYS[(s.getDay()+6)%7];
          var meta, pct = t.progress*100;
          if (t.state === 'live'){
            var el = (now - t.start_ms)/(t.end_ms - t.start_ms);
            pct = Math.max(pct, Math.min(Math.max(el,0),1)*100);
            meta = 'RUNNING &middot; '+hhmm(s)+' &ndash; '+hhmm(e)+' &middot; '+dur((t.end_ms-now)/1000)+' left';
          } else if (t.state === 'blocked'){
            meta = 'BLOCKED &middot; '+day+' '+hhmm(s)+' &middot; '+hrs(t.hours)+' booked';
          } else if (t.state === 'overdue'){
            meta = 'OVERDUE &middot; window closed '+day+' '+hhmm(e)+' &middot; '+dur((now-t.end_ms)/1000)+' ago';
          } else {
            meta = day+' '+hhmm(s)+' &middot; '+hrs(t.hours)
                 + ' &middot; starts in '+dur((t.start_ms-now)/1000);
          }
          void mode;
          var cl = t.checklist || [];
          var ticked = cl.filter(function(c){ return c.done; }).length;
          var effort = t.spanning ? ' &middot; '+hrs(t.effort)+' of work' : '';

          return '<div class="item" data-edit="'+esc(t.id)+'"><s style="background:'+col+'"></s><div class="b">'
               + '<div class="ttl"><span style="color:var(--text);font-weight:550;overflow:hidden;text-overflow:ellipsis">'+esc(t.title)+'</span>'
               + '<span>'+esc(t.track)+'</span></div>'
               + '<div class="mt mono">'+meta+effort+'</div>'
               + (t.notes ? '<div class="note">'+esc(t.notes)+'</div>' : '')
               + (cl.length
                   ? '<div class="chk">'+cl.map(function(c, ci){
                       return '<span class="'+(c.done?'y':'n')+'" data-task="'+esc(t.id)+'" data-i="'+ci+'"'
                            + ' title="Click to tick">'
                            + (c.done?'&#9745;':'&#9744;')+' '+esc(c.title)+'</span>'; }).join('')
                     + '<b>'+ticked+'/'+cl.length+'</b></div>'
                   : '')
               + '<div class="meter"><i style="width:'+pct+'%;background:'+col+'"></i></div>'
               + '</div></div>';
        }

        function panels(){
          var now = Date.now();
          var live = B.tasks.filter(function(t){ return t.state === 'live' || t.state === 'blocked' || t.state === 'overdue'; })
                            .sort(function(a,b){ return a.end_ms - b.end_ms; });
          var next = B.tasks.filter(function(t){ return t.state === 'upcoming'; })
                            .sort(function(a,b){ return a.start_ms - b.start_ms; }).slice(0,5);
          $('live').innerHTML = live.length
            ? live.map(function(t){ return itemHTML(t,'live'); }).join('')
            : '<div class="empty">Nothing running and nothing flagged. Clean board.</div>';
          $('nextlist').innerHTML = next.length
            ? next.map(function(t){ return itemHTML(t,'next'); }).join('')
            : '<div class="empty">Nothing else scheduled this week.</div>';
          $('livecount').innerHTML = B.stats.live + ' running &middot; ' + (B.stats.blocked + B.stats.overdue) + ' flagged';
          $('nextcount').textContent = next.length + ' queued';
          void now;
        }

        function chrome(){
          var w0 = new Date(ms(B.meta.week_start)), w1 = new Date(ms(B.meta.week_end) - 86400000);
          $('title').textContent = B.meta.title;
          $('sub').textContent = (B.meta.operator ? B.meta.operator + ' · ' : '')
            + B.tasks.length + ' tasks · ' + B.tracks.length + ' tracks';
          $('wklabel').textContent = w0.getDate()+' '+MON[w0.getMonth()]+' – '+w1.getDate()+' '+MON[w1.getMonth()];
          $('bpath').textContent = B.meta.board_path;
          $('ver').textContent = 'mission_control_dashboard v'+B.meta.version;
          document.body.className = B.read_only ? '' : 'editable';
          $('add').style.display    = B.read_only ? 'none' : '';
          $('romark').style.display = B.read_only ? '' : 'none';
          $('compress').className = S.compress ? 'on' : '';
          $('alldays').className  = S.allDays ? 'on' : '';
          $('today-btn').style.display = B.meta.week_offset === 0 ? 'none' : '';

          var wb = $('warnbox');
          wb.innerHTML = (B.warnings && B.warnings.length)
            ? '<div class="warn"><b>Board warnings</b><ul>'
              + B.warnings.map(function(w){ return '<li>'+esc(w)+'</li>'; }).join('') + '</ul></div>'
            : '';
        }

        function draw(){
          var sc = scale();
          chrome(); tiles(); panels();
          drawRuler(sc); drawRows(sc); drawNow(sc);
          if (!S.scrolled && B.meta.week_offset === 0 && sc.inside(Date.now())){
            S.scrolled = true;
            var el = $('scroll');
            el.scrollLeft = Math.max(0, sc.x(Date.now()) - el.clientWidth/2.6);
          }
        }

        function tickClock(){
          var d = new Date();
          $('clock').textContent = pad(d.getHours())+':'+pad(d.getMinutes())+':'+pad(d.getSeconds());
          $('today').textContent = DAYS[(d.getDay()+6)%7]+', '+d.getDate()+' '+MON[d.getMonth()]+' '+d.getFullYear();
          var cd = $('cd');
          if (cd && B.goal.set) cd.textContent = dur((ms(B.goal.due) - d.getTime())/1000);
          drawNow(scale());
        }

        // Poll defensively. A request with no timeout can hang indefinitely,
        // and overlapping polls stack up behind it — so bound every fetch and
        // never run two at once. If the server stops answering, say so in the
        // UI instead of quietly showing stale numbers as if they were live.
        var POLL = { inflight: false, misses: 0 };

        function fetchJSON(url, ms){
          var ctl = ('AbortController' in window) ? new AbortController() : null;
          var timer = setTimeout(function(){ if (ctl) ctl.abort(); }, ms || 10000);
          return fetch(url, { cache: 'no-store', signal: ctl ? ctl.signal : undefined })
            .then(function(r){ if (!r.ok) throw new Error('HTTP '+r.status); return r.json(); })
            .then(function(d){ clearTimeout(timer); return d; },
                  function(e){ clearTimeout(timer); throw e; });
        }

        function offline(on, why){
          var el = $('offline');
          el.style.display = on ? '' : 'none';
          if (on) el.innerHTML = '<b>Not responding</b> The dashboard is showing the last data it '
                               + 'received. ' + esc(why || '')
                               + '<br><span class="q">If the server is running in a console window on '
                               + 'Windows, click in it and press <b>Esc</b> — selecting text there pauses '
                               + 'the program.</span>';
        }

        function refresh(offset){
          var o = (offset === undefined) ? B.meta.week_offset : offset;
          if (POLL.inflight && offset === undefined) return Promise.resolve();
          POLL.inflight = true;

          return fetchJSON('/api/board?week='+o)
            .then(function(d){
              POLL.inflight = false; POLL.misses = 0; offline(false);
              B = d; if (offset !== undefined) S.scrolled = false; draw();
            })
            .catch(function(e){
              POLL.inflight = false;
              POLL.misses += 1;
              if (POLL.misses >= 2) offline(true, e.name === 'AbortError'
                ? 'The last request timed out.' : esc(e.message));
              console.warn('refresh failed:', e.message);
            });
        }

        /* ================= editing ================= */

        var EDIT = { id: null, checklist: [], touchedProgress: false, busy: false };

        function api(method, path, payload){
          return fetch(path, {
            method: method,
            cache: 'no-store',
            headers: { 'Content-Type': 'application/json', 'X-Mission-Control': '1' },
            body: payload ? JSON.stringify(payload) : undefined
          }).then(function(r){
            return r.json().catch(function(){ return {}; }).then(function(d){
              if (!r.ok) { var e = new Error(d.error || ('HTTP '+r.status)); e.status = r.status; throw e; }
              return d;
            });
          });
        }

        var toastTimer;
        function toast(msg, kind, sticky){
          var el = $('toast');
          el.className = 'toast on ' + (kind || '');
          el.innerHTML = msg + (sticky ? '<div><button onclick="location.reload()">Reload the page</button></div>' : '');
          clearTimeout(toastTimer);
          if (!sticky) toastTimer = setTimeout(function(){ el.className = 'toast ' + (kind||''); }, 4200);
        }

        function failed(e){
          if (e.status === 409){
            toast('<b>Save rejected — the file changed underneath you.</b>'+esc(e.message), 'bad', true);
          } else {
            toast('<b>Could not save</b>'+esc(e.message), 'bad');
          }
        }

        function drawChecklist(){
          var box = $('f-checklist');
          box.innerHTML = EDIT.checklist.map(function(c, i){
            return '<div class="cl-row">'
                 + '<input type="checkbox" data-i="'+i+'"'+(c.done?' checked':'')+'>'
                 + '<input type="text" data-i="'+i+'" value="'+esc(c.title)+'" placeholder="Step">'
                 + '<button data-i="'+i+'" class="danger">&times;</button></div>';
          }).join('');
          Array.prototype.forEach.call(box.querySelectorAll('input[type=checkbox]'), function(el){
            el.onchange = function(){ EDIT.checklist[+this.dataset.i].done = this.checked; syncProgressFromChecklist(); };
          });
          Array.prototype.forEach.call(box.querySelectorAll('input[type=text]'), function(el){
            el.oninput = function(){ EDIT.checklist[+this.dataset.i].title = this.value; };
          });
          Array.prototype.forEach.call(box.querySelectorAll('button'), function(el){
            el.onclick = function(){ EDIT.checklist.splice(+this.dataset.i, 1); drawChecklist(); syncProgressFromChecklist(); };
          });
        }

        function syncProgressFromChecklist(){
          var hint = $('f-progress-hint');
          if (EDIT.checklist.length && !EDIT.touchedProgress){
            var pct = Math.round(EDIT.checklist.filter(function(c){return c.done;}).length
                                 / EDIT.checklist.length * 100);
            $('f-progress').value = pct;
            $('f-progress-v').textContent = pct+'%';
            hint.innerHTML = 'Derived from the checklist. Move the slider to override.';
          } else {
            hint.innerHTML = EDIT.checklist.length ? 'Overriding the checklist.' : '&nbsp;';
          }
        }

        function openEditor(task){
          if (B.read_only) return;
          EDIT.id = task ? task.id : null;
          EDIT.checklist = task && task.checklist ? task.checklist.map(function(c){
            return { title: c.title, done: !!c.done }; }) : [];
          EDIT.touchedProgress = !!(task && task.progress > 0 && !(task.checklist||[]).length);

          $('mtitle').textContent = task ? 'Edit task' : 'New task';
          $('f-delete').style.display = task ? '' : 'none';
          $('merr').className = 'err';

          $('f-title').value    = task ? task.title : '';
          $('f-track').value    = task ? task.track : (B.tracks[0] || 'General');
          $('f-status').value   = task ? task.status : 'todo';
          $('f-owner').value    = task ? (task.owner || '') : '';
          $('f-notes').value    = task ? (task.notes || '') : '';
          $('f-effort').value   = task && task.spanning ? task.effort : '';
          $('f-progress').value = task ? Math.round(task.progress*100) : 0;
          $('f-progress-v').textContent = (task ? Math.round(task.progress*100) : 0)+'%';

          if (task){
            var s = new Date(task.start_ms), e = new Date(task.end_ms);
            $('f-start').value = DAYS[(s.getDay()+6)%7].toLowerCase()+' '+hhmm(s);
            $('f-end').value   = DAYS[(e.getDay()+6)%7].toLowerCase()+' '+hhmm(e);
            $('f-duration').value = '';
          } else {
            var n = new Date(), h = Math.min(n.getHours()+1, 22);
            $('f-start').value = DAYS[(n.getDay()+6)%7].toLowerCase()+' '+pad(h)+':00';
            $('f-end').value = '';
            $('f-duration').value = 2;
          }

          $('tracklist').innerHTML = B.tracks.map(function(t){
            return '<option value="'+esc(t)+'">'; }).join('');

          drawChecklist(); syncProgressFromChecklist();
          $('scrim').style.display = 'flex';
          setTimeout(function(){ $('f-title').focus(); }, 30);
        }

        function closeEditor(){ $('scrim').style.display = 'none'; EDIT.id = null; }

        function collect(){
          var t = {
            title:  $('f-title').value.trim(),
            track:  $('f-track').value.trim() || 'General',
            status: $('f-status').value,
            start:  $('f-start').value.trim(),
            owner:  $('f-owner').value.trim(),
            notes:  $('f-notes').value.trim(),
            checklist: EDIT.checklist.filter(function(c){ return c.title.trim(); })
          };
          var end = $('f-end').value.trim(), dur = parseFloat($('f-duration').value);
          if (end) { t.end = end; } else if (dur > 0) { t.duration = dur; }
          var eff = parseFloat($('f-effort').value);
          if (eff > 0) t.effort = eff;
          var p = +$('f-progress').value;
          // Only send progress when it is genuinely a manual override —
          // otherwise let the checklist derive it server-side.
          if (t.status !== 'done' && (EDIT.touchedProgress || !t.checklist.length) && p > 0) t.progress = p/100;
          return t;
        }

        function save(){
          if (EDIT.busy) return;
          var task = collect();
          if (!task.title){ showErr('Give it a title.'); return; }
          if (!task.start){ showErr('Give it a start time, e.g. "wed 10:00".'); return; }
          if (!task.end && !task.duration){ showErr('Set an End or a Duration.'); return; }

          EDIT.busy = true; $('f-save').textContent = 'Saving...';
          var req = EDIT.id
            ? api('PATCH', '/api/tasks/'+encodeURIComponent(EDIT.id), { task: task, rev: B.rev })
            : api('POST', '/api/tasks', { task: task, rev: B.rev });

          req.then(function(){
            closeEditor();
            toast('<b>Saved to YAML</b>'+esc(B.meta.board_path), 'ok');
            return refresh();
          }).catch(function(e){
            if (e.status === 409){ closeEditor(); failed(e); } else { showErr(e.message); }
          }).then(function(){
            EDIT.busy = false; $('f-save').textContent = 'Save to YAML';
          });
        }

        function removeTask(){
          if (!EDIT.id || EDIT.busy) return;
          if (!confirm('Delete "'+$('f-title').value+'" from the board file?')) return;
          EDIT.busy = true;
          api('DELETE', '/api/tasks/'+encodeURIComponent(EDIT.id), { rev: B.rev })
            .then(function(){ closeEditor(); toast('<b>Removed from YAML</b>', 'ok'); return refresh(); })
            .catch(function(e){ closeEditor(); failed(e); })
            .then(function(){ EDIT.busy = false; });
        }

        function showErr(msg){ var e = $('merr'); e.textContent = msg; e.className = 'err on'; }

        // Tick a checklist box straight from the card, no modal.
        function toggleItem(taskId, index){
          var t = B.tasks.filter(function(x){ return x.id === taskId; })[0];
          if (!t || B.read_only) return;
          var list = (t.checklist || []).map(function(c, i){
            return { title: c.title, done: i === index ? !c.done : !!c.done }; });
          api('PATCH', '/api/tasks/'+encodeURIComponent(taskId), { task: { checklist: list }, rev: B.rev })
            .then(function(){ return refresh(); })
            .catch(failed);
        }

        function byId(id){
          var m = B.tasks.filter(function(t){ return t.id === id; });
          return m.length ? m[0] : null;
        }

        // One delegated listener beats rebinding handlers on every redraw.
        document.addEventListener('click', function(ev){
          if (B.read_only) return;
          var chk = ev.target.closest ? ev.target.closest('.chk span') : null;
          if (chk && chk.dataset.task){ toggleItem(chk.dataset.task, +chk.dataset.i); return; }
          var hit = ev.target.closest ? ev.target.closest('[data-edit]') : null;
          if (hit){ var t = byId(hit.dataset.edit); if (t) openEditor(t); }
        });

        $('add').onclick      = function(){ openEditor(null); };
        $('mclose').onclick   = closeEditor;
        $('f-cancel').onclick = closeEditor;
        $('f-save').onclick   = save;
        $('f-delete').onclick = removeTask;
        $('f-additem').onclick = function(){
          EDIT.checklist.push({ title: '', done: false }); drawChecklist(); syncProgressFromChecklist();
        };
        $('f-progress').oninput = function(){
          EDIT.touchedProgress = true;
          $('f-progress-v').textContent = this.value+'%';
          syncProgressFromChecklist();
        };
        $('scrim').onclick = function(ev){ if (ev.target === this) closeEditor(); };
        document.addEventListener('keydown', function(ev){
          if ($('scrim').style.display === 'none') return;
          if (ev.key === 'Escape') closeEditor();
          if (ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey)) save();
        });

        $('wk-prev').onclick = function(){ refresh(B.meta.week_offset - 1); };
        $('wk-next').onclick = function(){ refresh(B.meta.week_offset + 1); };
        $('today-btn').onclick = function(){ refresh(0); };
        $('zoom').oninput  = function(){ S.px = +this.value; draw(); };
        $('compress').onclick = function(){
          S.compress = !S.compress; S.scrolled = false;
          S.px = fitZoom(); $('zoom').value = S.px; draw();
        };
        $('alldays').onclick  = function(){
          S.allDays = !S.allDays; S.scrolled = false;
          S.px = fitZoom(); $('zoom').value = S.px; draw();
        };

        S.compress = B.meta.compress !== false;
        S.px = fitZoom();
        $('zoom').value = S.px;
        draw();
        tickClock();
        setInterval(tickClock, 1000);
        setInterval(function(){ refresh(); }, 20000);
        window.addEventListener('resize', function(){ drawNow(scale()); });
      })();
      </script>
      </body>
      </html>
    HTML
  end
end
