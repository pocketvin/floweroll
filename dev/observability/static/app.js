'use strict';
const $ = id => document.getElementById(id);
const states = {
  active:'进行中', completed:'已完成', blocked:'已暂停', failed:'失败', cancelled:'已取消', waiting:'等待中', accepted:'已接收', succeeded:'已成功', response_validated:'响应已验证', error:'调用失败', request_ready:'请求已组装',
  recording:'观察中', finalizing:'整理中', analysis_failed:'整理失败'
};
const sourceLabels = {screen:'屏幕', ambientMicrophone:'周围麦克风', deviceAudio:'手机音频', system:'系统'};
const eventLabels = {screen:'屏幕', transcript:'转写', lifecycle:'状态', gap:'记录缺口'};
const tabs = [['system_prompt','System Prompt'],['context','上下文'],['tools','工具集'],['wire_request','原始请求'],['model_response','模型结果'],['prompt_diff','Prompt 对比'],['contract_check','结构检查']];
let tasks = [], observations = [], surface = 'tasks', selected = null, selectedObservation = null;
let callNumber = null, callData = null, activeTab = 'system_prompt', overviewFingerprint = '', observationFingerprint = '', refreshing = false, callRequest = 0;

function el(tag,text,cls){const e=document.createElement(tag);if(text!==undefined&&text!==null)e.textContent=text;if(cls)e.className=cls;return e;}
function pretty(x){return typeof x === 'string' ? x : JSON.stringify(x,null,2);}
function duration(ms){if(ms==null)return '未知';if(ms<1000)return `${Math.round(ms)} ms`;if(ms<60000)return `${(ms/1000).toFixed(1)} 秒`;return `${Math.floor(ms/60000)} 分 ${Math.floor(ms%60000/1000)} 秒`;}
function time(x){return x?new Date(x).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}):'未知';}
function percent(x){return `${Math.round(Math.max(0,Math.min(1,Number(x)||0))*100)}%`;}
async function api(path){const r=await fetch(path,{headers:{'X-Floweroll-Console':'1'},cache:'no-store'});const d=await r.json();if(!r.ok)throw new Error(d.error || `HTTP ${r.status}`);return d;}

function drawTasks(){
  const list=$('task-list');list.replaceChildren();const q=$('search').value.trim().toLowerCase();
  const visible=tasks.filter(t=>`${t.goal} ${t.id}`.toLowerCase().includes(q));$('list-count').textContent=`${visible.length} 条`;
  for(const t of visible){
    const b=el('button',undefined,'task'+(selected===t.id?' selected':''));b.type='button';b.dataset.task=t.id;b.setAttribute('aria-pressed',String(selected===t.id));
    b.append(el('span',t.goal,'title'));const c=el('span',undefined,'caption');c.append(el('span',states[t.status]||t.status),el('span',time(t.updated_at)));b.append(c);b.onclick=()=>selectTask(t.id);list.append(b);
  }
  if(!visible.length)list.append(el('p','没有符合条件的任务。','muted'));
}

function drawObservations(){
  const list=$('observation-list');list.replaceChildren();const q=$('search').value.trim().toLowerCase();
  const visible=observations.filter(o=>`${o.title||''} ${o.preset_label||''} ${o.id} ${(o.sources||[]).join(' ')}`.toLowerCase().includes(q));$('list-count').textContent=`${visible.length} 条`;
  for(const o of visible){
    const b=el('button',undefined,'task observation-item'+(selectedObservation===o.id?' selected':''));b.type='button';b.dataset.observation=o.id;b.setAttribute('aria-pressed',String(selectedObservation===o.id));
    b.append(el('span',o.title||o.preset_label||`观察 ${o.id.slice(0,8)}`,'title'));
    const sources=(o.sources||[]).map(x=>sourceLabels[x]||x).join(' · ');
    const c=el('span',undefined,'caption');c.append(el('span',`${states[o.status]||o.status} · ${o.event_count||0} 条`),el('span',time(o.updated_at)));b.append(c);
    if(sources)b.append(el('span',sources,'source-caption'));
    b.onclick=()=>selectObservation(o.id);list.append(b);
  }
  if(!visible.length)list.append(el('p','还没有可读取的观察记录。','muted'));
}

function setSurface(next,{selectDefault=true}={}){
  surface=next;
  const isTasks=next==='tasks';
  $('surface-tasks').classList.toggle('selected',isTasks);$('surface-tasks').setAttribute('aria-selected',String(isTasks));
  $('surface-observations').classList.toggle('selected',!isTasks);$('surface-observations').setAttribute('aria-selected',String(!isTasks));
  $('task-list').hidden=!isTasks;$('observation-list').hidden=isTasks;$('detail').hidden=true;$('observation-detail').hidden=true;
  $('list-title').textContent=isTasks?'最近任务':'最近观察';$('search').placeholder=isTasks?'搜索任务或 ID':'搜索观察、模式或 ID';
  $('list-note').textContent=isTasks?'来自真实 Host 数据库 · 只读\n每 6 秒刷新，不执行任务或调用模型':'来自独立 Observation SQLite · 只读\n不执行模型，不读取实时麦克风电平';
  $('welcome').hidden=false;$('welcome-title').textContent=isTasks?'先选一条任务':'先选一段观察';
  $('welcome-copy').textContent=isTasks?'查看小卷实际给模型的 Prompt、上下文、工具，以及模型返回后到底发生了什么。':'查看观察来源、durable evidence、屏幕理解、整理覆盖率、Checkpoint / Final Summary 和错误/降级原因。';
  $('welcome-note').textContent=isTasks?'旧任务没有记录的请求会明确显示「未采集」，不会用当前模板倒推。':'完整 transcript/summary 只在 local_full 展示；截图原始 base64 永远不会通过开发观察台 API 返回。';
  if(isTasks)drawTasks();else drawObservations();
  if(selectDefault){
    if(isTasks&&selected)selectTask(selected,true);else if(isTasks&&tasks.length)selectTask(tasks[0].id);
    if(!isTasks&&selectedObservation)selectObservation(selectedObservation,true);else if(!isTasks&&observations.length)selectObservation(observations[0].id);
  }
}

function drawOverview(d){
  const s=d.summary;$('detail').hidden=false;$('observation-detail').hidden=true;$('welcome').hidden=true;$('goal').textContent=d.goal;$('task-status').textContent=states[d.task.status]||d.task.status;$('task-id').textContent=d.task.id.slice(0,8);$('trace-link').href=d.trace_url;
  $('task-note').textContent=`已完整采集 ${s.full_captured_calls} 次请求。费用未知；未报告的 Token 不当作零。${s.calls_without_reported_usage?`有 ${s.calls_without_reported_usage} 次调用未报告完整用量。`:''}`;
  const metrics=$('metrics');metrics.replaceChildren();for(const [value,label] of [[duration(s.elapsed_ms),'任务跨度（含等待 / 暂停）'],[s.planner_calls,'Planner 调用'],[s.actions,'工具动作'],[Number(s.reported_tokens_only||0).toLocaleString(),'已报告 Token'],[duration(s.model_ms_sum),'模型耗时累计（非墙钟总时长）']]){const box=el('div',undefined,'metric');box.append(el('strong',String(value)),el('span',label));metrics.append(box);}
  const openKeys=new Set([...document.querySelectorAll('#events details[open]')].map(x=>x.dataset.key));const box=$('events');box.replaceChildren();
  for(const e of d.events){const row=el('div',undefined,'event'+(e.error?' error':'')+(e.call_number===callNumber?' selected':''));row.dataset.key=e.key;const head=el(e.call_number?'button':'div');if(e.call_number){head.type='button';head.onclick=()=>selectCall(e.call_number);}const top=el('div',undefined,'row');top.append(el('strong',e.name),el('span',e.in_flight?'处理中':duration(e.duration_ms),'small'));head.append(top);const caption=[time(e.at),e.status?(states[e.status]||e.status):'',e.call_number?(e.capture_available?'实际请求可查看':'完整请求未采集'):null].filter(Boolean).join(' · ');head.append(el('div',caption,'caption'));row.append(head);
    if(!e.call_number&&(e.input||e.output)){const detail=el('details');detail.dataset.key=e.key;detail.open=openKeys.has(e.key);detail.append(el('summary','查看工具参数 / 结果 / 事件证据'),el('pre',pretty({input:e.input,output:e.output})));row.append(detail);}box.append(row);}
  const evidence=$('evidence');evidence.replaceChildren();if(!s.layer_evidence.length)evidence.append(el('p','没有记录到所覆盖类型的失败 / 恢复事件；这不等于全链路质量已经验收。','muted'));
  for(const e of s.layer_evidence){const row=el('div',undefined,'evidence-row');row.append(el('strong',e.layer),el('span',e.claim+(e.reason?` 原因码：${e.reason}`:'')),el('span',`${time(e.at)} · #${e.event_id}`,'time'));evidence.append(row);}
}

async function selectTask(id,quiet=false){
  if(!quiet){selected=id;callNumber=null;callData=null;callRequest++;overviewFingerprint='';location.hash='task:'+id;$('call-title').textContent='请求检查器';$('call-note').textContent='选择一次 Planner 调用查看当时的实际请求。';$('tabs').replaceChildren();$('payload').textContent='暂无选中调用';$('call-meta').textContent='';drawTasks();}
  const requested=id;try{const d=await api(`/api/tasks/${id}`);if(selected!==requested||surface!=='tasks')return;const fp=JSON.stringify([d.task,d.summary,d.events]);if(fp!==overviewFingerprint){drawOverview(d);overviewFingerprint=fp;}if(!quiet){const captured=d.events.find(e=>e.call_number&&e.capture_available);if(captured)await selectCall(captured.call_number);}}catch(e){$('notice').textContent='读取失败：'+e.message;}
}

function drawTab(){for(const b of $('tabs').children)b.classList.toggle('selected',b.dataset.tab===activeTab);if(!callData)return;let value=callData[activeTab];if(activeTab==='prompt_diff'&&!value)value=callData.prompt_matches_current?'与当前源码完全一致。注意：当前源码不一定等于其他历史调用所用版本。':'未记录，无法比较。';$('payload').textContent=value==null?'没有记录到该内容。':pretty(value);}
async function selectCall(n){const request=++callRequest;const task=selected;callNumber=n;callData=null;$('call-title').textContent=`Planner #${n}`;$('call-note').textContent='正在读取实际请求…';$('payload').textContent='读取中';for(const x of document.querySelectorAll('#events .event'))x.classList.toggle('selected',x.dataset.key===`planner:${n}`);
  try{const d=await api(`/api/tasks/${task}/calls/${n}`);if(request!==callRequest||selected!==task||surface!=='tasks')return;callData=d;$('call-note').textContent=d.note;const m=d.metadata;$('call-meta').textContent=[m.prompt?.sha256?`Prompt SHA ${m.prompt.sha256.slice(0,16)}`:'',m.request_bytes?`请求 ${Number(m.request_bytes).toLocaleString()} bytes`:'',m.state?`采集状态 ${states[m.state]||m.state}`:''].filter(Boolean).join(' · ');$('tabs').replaceChildren();if(!d.available){$('payload').textContent=pretty({metadata:d.metadata,metrics:d.metrics});return;}
    for(const [key,label] of tabs){const b=el('button',label);b.type='button';b.dataset.tab=key;b.onclick=()=>{activeTab=key;drawTab();};$('tabs').append(b);}drawTab();}catch(e){if(request===callRequest)$('payload').textContent='读取失败：'+e.message;}}

function noteTitle(notes,session){for(let i=notes.length-1;i>=0;i--){if(notes[i].title)return notes[i].title;}return session.preset_label||`观察 ${session.id.slice(0,8)}`;}
function drawObservation(d){
  const s=d.session, stats=d.stats, analysis=d.analysis;$('observation-detail').hidden=false;$('detail').hidden=true;$('welcome').hidden=true;
  $('observation-status').textContent=states[s.status]||s.status;$('observation-id').textContent=s.id.slice(0,8);$('observation-preset').textContent=s.preset_label||s.preset||'';$('observation-title').textContent=noteTitle(d.notes,s);
  const sourceText=(s.sources||[]).map(x=>sourceLabels[x]||x).join(' · ');$('observation-note').textContent=`${sourceText||'无来源'} · ${time(s.created_at)} 开始 · ${d.privacy.content_included?'local_full 可查看正文':'当前模式只显示元数据'}。原始截图不会通过此 API 返回。`;
  const metrics=$('observation-metrics');metrics.replaceChildren();const transcript=stats.kind_counts.transcript||0;
  for(const [value,label] of [[stats.event_count,'Durable 事件'],[transcript,'转写片段'],[`${stats.screen_understood}/${stats.screen_total}`,'屏幕理解'],[stats.checkpoint_count,'Checkpoint'],[analysis.pending_events,'未覆盖事件']]){const box=el('div',undefined,'metric');box.append(el('strong',String(value)),el('span',label));metrics.append(box);}

  const timeline=$('observation-timeline');timeline.replaceChildren();
  if(!d.timeline.length)timeline.append(el('p','这段观察还没有 durable event。','muted'));
  for(const e of d.timeline){const row=el('div',undefined,'event observation-event'+(e.screen_error||e.kind==='gap'?' error':''));const top=el('div',undefined,'row');top.append(el('strong',`${eventLabels[e.kind]||e.kind||'事件'} · ${sourceLabels[e.source]||e.source||'未知来源'}`),el('span',`#${e.seq}`,'small'));row.append(top);
    const meta=[time(e.captured_at),e.offset_ms!=null?`+${duration(e.offset_ms)}`:null,e.duration_ms?`持续 ${duration(e.duration_ms)}`:null,e.has_screen_understanding?'已理解画面':null,e.screen_skipped?`视觉跳过 ${e.screen_skipped}`:null,e.screen_error?`视觉错误 ${e.screen_error}`:null].filter(Boolean).join(' · ');row.append(el('div',meta,'caption'));
    if(e.text)row.append(el('p',e.text,'observation-text'));
    if(e.screen_understanding){const insight=el('div',undefined,'screen-insight');if(e.screen_understanding.page_type)insight.append(el('span',e.screen_understanding.page_type,'badge'));if(e.screen_understanding.summary)insight.append(el('p',e.screen_understanding.summary));const details=[['关键项',e.screen_understanding.key_items],['可见操作',e.screen_understanding.visible_actions],['不确定',e.screen_understanding.uncertainties]];for(const [label,items] of details){if(items?.length)insight.append(el('div',`${label}：${items.join('；')}`,'small'));}row.append(insight);}timeline.append(row);}

  const analysisBox=$('observation-analysis');analysisBox.replaceChildren();
  const analysisRows=[['Durable 状态',states[analysis.durable_status]||analysis.durable_status],['整理覆盖',`${percent(analysis.coverage)} · ${analysis.covered_events}/${analysis.event_count} 条`],['待整理事件',String(analysis.pending_events)],['整理游标',`#${analysis.summary_through_seq} · 最新 #${analysis.last_seq}`],['最后错误',analysis.last_error||'无'],['重试时间',analysis.retry_after?time(analysis.retry_after):'无']];
  for(const [label,value] of analysisRows){const box=el('div',undefined,'analysis-item');box.append(el('span',label,'small'),el('strong',value));analysisBox.append(box);}

  const sources=$('observation-sources');sources.replaceChildren();const configured=new Set(s.sources||[]);const entries=Object.entries(stats.source_stats||{}).sort(([a],[b])=>Number(!configured.has(a))-Number(!configured.has(b))||a.localeCompare(b));
  for(const [key,value] of entries){const card=el('div',undefined,'source-card');card.append(el('strong',sourceLabels[key]||key));card.append(el('span',`${value.events} 条事件`,'small'));const parts=[];if(value.transcripts)parts.push(`${value.transcripts} 转写`);if(value.screens)parts.push(`${value.screens} 屏幕`);if(value.gaps)parts.push(`${value.gaps} 缺口`);card.append(el('span',parts.join(' · ')||'尚无证据','source-detail'));if(value.latest_captured_at)card.append(el('span',`最近 ${time(value.latest_captured_at)}`,'small'));sources.append(card);}
  if(!entries.length)sources.append(el('p','没有来源证据。','muted'));

  const notes=$('observation-notes');notes.replaceChildren();
  if(!d.notes.length)notes.append(el('p','还没有 Checkpoint / Final Summary。','muted'));
  for(const n of d.notes){const card=el('article',undefined,'note-card');const head=el('div',undefined,'row');head.append(el('strong',n.kind==='final'?'Final Summary':'Checkpoint'),el('span',`覆盖到 #${n.through_seq} · ${time(n.created_at)}`,'small'));card.append(head);if(n.title)card.append(el('h3',n.title));if(n.summary)card.append(el('p',n.summary));else card.append(el('p',`正文在当前采集模式下隐藏 · 引用 ${n.evidence_count} 条 evidence`,'muted'));for(const [label,items] of [['决定',n.decisions],['待办',n.todos],['待确认',n.open_questions]]){if(items?.length){const group=el('div',undefined,'note-items');group.append(el('strong',label));for(const item of items)group.append(el('p',item.text));card.append(group);}}notes.append(card);}

  const qPanel=$('observation-questions-panel'),questions=$('observation-questions');questions.replaceChildren();qPanel.hidden=!d.questions.length;
  for(const q of d.questions){const card=el('article',undefined,'note-card');card.append(el('strong',`${states[q.status]||q.status}${q.error?` · ${q.error}`:''}`));if(q.question)card.append(el('p',q.question));if(q.result?.summary)card.append(el('p',q.result.summary,'muted'));questions.append(card);}
}

async function selectObservation(id,quiet=false){
  if(!quiet){selectedObservation=id;observationFingerprint='';location.hash='obs:'+id;drawObservations();}
  const requested=id;try{const d=await api(`/api/observations/${id}`);if(selectedObservation!==requested||surface!=='observations')return;const fp=JSON.stringify(d);if(fp!==observationFingerprint){drawObservation(d);observationFingerprint=fp;}}catch(e){$('notice').textContent='观察记录读取失败：'+e.message;}
}

async function refresh(){
  if(refreshing)return;refreshing=true;
  try{
    const [status,taskIndex,observationIndex]=await Promise.all([api('/api/status'),api('/api/tasks'),api('/api/observations')]);tasks=taskIndex.tasks;observations=observationIndex.observations||[];
    if(surface==='tasks')drawTasks();else drawObservations();
    $('mode').textContent=({local_full:'本机完整采集',metadata:'仅元数据',off:'采集已关闭'})[status.mode];$('langfuse').href=status.langfuse_url;$('prompts-link').href=status.prompts_url;
    const x=status.export;const age=x.checked_at?(Date.now()-new Date(x.checked_at).getTime())/1000:null;$('export-status').textContent=`Langfuse 导出：${age==null?'尚未运行':age>60?'更新滞后，请检查导出进程':'运行中'}${x.export_error_type?' · '+x.export_error_type:''}${x.checked_at?' · '+time(x.checked_at):''}`;$('notice').textContent='';
    if(surface==='tasks'&&selected)await selectTask(selected,true);if(surface==='observations'&&selectedObservation)await selectObservation(selectedObservation,true);
  }catch(e){$('notice').textContent='观察台读取失败：'+e.message+'。这不代表小卷任务或观察失败。';}finally{refreshing=false;}
}

$('search').oninput=()=>surface==='tasks'?drawTasks():drawObservations();
$('refresh').onclick=async()=>{await refresh();if(surface==='tasks'&&callNumber)await selectCall(callNumber);};
$('surface-tasks').onclick=()=>setSurface('tasks');$('surface-observations').onclick=()=>setSurface('observations');
async function initial(){await refresh();const raw=location.hash.slice(1);if(raw.startsWith('obs:')){const id=raw.slice(4);setSurface('observations',{selectDefault:false});if(observations.some(x=>x.id===id))await selectObservation(id);else if(observations.length)await selectObservation(observations[0].id);}else{const id=raw.startsWith('task:')?raw.slice(5):raw;setSurface('tasks',{selectDefault:false});if(tasks.some(t=>t.id===id))await selectTask(id);else if(tasks.length)await selectTask(tasks[0].id);}}
initial();setInterval(()=>{if(!document.hidden)refresh();},6000);
