import {useCallback,useEffect,useRef,useState} from 'react';
import {Graph} from './Graph';
import {get,count,millis,bytes,text,size,statusLabel,modelOperation} from './api';
import type {Topology,ExecutionPath,CallDetail,Task,Observation,Selection,Status,Inspect,Component,Span,Link,ModelDetail} from './types';

function initialSelection():Selection{const match=location.hash.match(/^#(task|observation)\/([0-9a-f-]+)$/i);return match?{kind:match[1] as 'task'|'observation',id:match[2]}:{kind:'overall'}}
function storedFlag(key:string,fallback:boolean){try{return localStorage.getItem(key)==null?fallback:localStorage.getItem(key)==='true'}catch{return fallback}}
const errorText=(e:unknown)=>e instanceof Error?e.message:String(e);
const spanTime=(span:Span)=>{if(!span.started_at)return null;const value=Date.parse(span.started_at);return Number.isFinite(value)?value:null};
const chronological=(spans:Span[])=>spans.map((span,index)=>({span,index,time:spanTime(span)})).sort((a,b)=>a.time===null&&b.time===null?a.index-b.index:a.time===null?1:b.time===null?-1:a.time-b.time||a.index-b.index).map(item=>item.span);
const clock=(value:string|null)=>{if(!value)return '时间未记录';const date=new Date(value);if(Number.isNaN(date.getTime()))return '时间未记录';return `${date.toLocaleTimeString('zh-CN',{hour12:false})}.${String(date.getMilliseconds()).padStart(3,'0')}`};

export default function App(){
 const [selection,setSelection]=useState<Selection>(initialSelection);const [topology,setTopology]=useState<Topology|null>(null);
 const [tasks,setTasks]=useState<Task[]>([]);const [observations,setObservations]=useState<Observation[]>([]);const [status,setStatus]=useState<Status|null>(null);
 const [path,setPath]=useState<ExecutionPath|null>(null);const [mode,setMode]=useState<'system'|'execution'>(()=>initialSelection().kind==='overall'?'system':'execution');
 const [navTab,setNavTab]=useState<'tasks'|'observations'>('tasks');const [navQuery,setNavQuery]=useState('');const [collapsed,setCollapsed]=useState(()=>storedFlag('floweroll.sidebar.collapsed',false));
 const [shelf,setShelf]=useState(true);const [focus,setFocus]=useState(false);const [topologyOpen,setTopologyOpen]=useState(false);const [requestTab,setRequestTab]=useState('messages');const [requestExpanded,setRequestExpanded]=useState(false);const [requestCopied,setRequestCopied]=useState<string|null>(null);const [focusKey,setFocusKey]=useState(0);
 const [observationCallId,setObservationCallId]=useState<string|null>(null);const [observationModel,setObservationModel]=useState<ModelDetail|null>(null);const manualObservation=useRef(false);
 const [callNumber,setCallNumber]=useState<number|null>(null);const [detail,setDetail]=useState<CallDetail|null>(null);const [callError,setCallError]=useState<string|null>(null);
 const [inspect,setInspect]=useState<Inspect|null>(null);const [expandedInspector,setExpandedInspector]=useState(false);const [copied,setCopied]=useState(false);
 const [error,setError]=useState<string|null>(null);const [pathError,setPathError]=useState<string|null>(null);const [loading,setLoading]=useState(false);const [auto,setAuto]=useState(true);const [refresh,setRefresh]=useState(0);
 const inspectSeq=useRef(0);const manualCall=useRef(false);
 const selectionId=selection.kind==='overall'?'':selection.id;
 const choose=useCallback((value:Selection)=>{inspectSeq.current++;setSelection(value);setPath(null);setPathError(null);setDetail(null);setInspect(null);setCallNumber(null);setRequestTab(value.kind==='observation'?'system_prompt':'messages');setRequestExpanded(false);setRequestCopied(null);manualCall.current=false;manualObservation.current=false;setObservationCallId(null);setObservationModel(null);setMode(value.kind==='overall'?'system':'execution');
   location.hash=value.kind==='overall'?'':`${value.kind}/${value.id}`;setFocusKey(x=>x+1)},[]);
 useEffect(()=>{const controller=new AbortController();let busy=false;
   async function read(force=false){if(busy||(!force&&document.hidden))return;busy=true;
     const values=await Promise.allSettled([get<Topology>('/api/topology',controller.signal),get<{tasks:Task[]}>('/api/tasks',controller.signal),get<{observations:Observation[]}>('/api/observations',controller.signal),get<Status>('/api/status',controller.signal)]);
     if(controller.signal.aborted)return;
     if(values[0].status==='fulfilled'){setTopology(values[0].value);setError(null)}else setError(errorText(values[0].reason));
     if(values[1].status==='fulfilled')setTasks(values[1].value.tasks);
     if(values[2].status==='fulfilled')setObservations(values[2].value.observations);
     if(values[3].status==='fulfilled')setStatus(values[3].value);
     busy=false;
   }
   void read(true);const interval=auto?setInterval(()=>void read(),10000):undefined;return()=>{controller.abort();clearInterval(interval)}
 },[auto,refresh]);
 useEffect(()=>{if(selection.kind==='overall')return;const controller=new AbortController();let busy=false;
   async function read(force=false){if(busy||(!force&&document.hidden))return;busy=true;setLoading(true);
     try{const value=await get<ExecutionPath>(`/api/${selection.kind==='task'?'tasks':'observations'}/${selectionId}/path`,controller.signal);
       if(controller.signal.aborted)return;setPath(value);setPathError(null);
       if(!manualCall.current)setCallNumber(value.planner_calls.at(-1)?.call_number??null);
       if(!manualObservation.current)setObservationCallId(value.model_calls?.at(-1)?.capture_id??null);
     }catch(e){if(!controller.signal.aborted)setPathError(errorText(e))}finally{if(!controller.signal.aborted){setLoading(false);busy=false}}
   }
   void read(true);const interval=auto?setInterval(()=>void read(),6000):undefined;return()=>{controller.abort();clearInterval(interval)}
 },[selection.kind,selectionId,auto,refresh]);
 useEffect(()=>{if(selection.kind!=='task'||callNumber===null){setDetail(null);return}const controller=new AbortController();setCallError(null);
   get<CallDetail>(`/api/tasks/${selectionId}/calls/${callNumber}`,controller.signal).then(v=>{if(!controller.signal.aborted)setDetail(v)}).catch(e=>{if(!controller.signal.aborted)setCallError(errorText(e))});
   return()=>controller.abort();
 },[selection.kind,selectionId,callNumber,path?.checked_at]);
 useEffect(()=>{setDetail(null)},[selectionId,callNumber]);
 useEffect(()=>{setObservationModel(null)},[selectionId,observationCallId]);
 useEffect(()=>{
   if(selection.kind!=='observation'||!observationCallId){setObservationModel(null);return}
   const controller=new AbortController();setCallError(null);
   get<ModelDetail>(`/api/observations/${selectionId}/calls/${observationCallId}`,controller.signal).then(value=>{
      if(!controller.signal.aborted)setObservationModel(value)
   }).catch(e=>{if(!controller.signal.aborted)setCallError(errorText(e))});
   return()=>controller.abort();
 },[selection.kind,selectionId,observationCallId,path?.checked_at]);
 useEffect(()=>{try{localStorage.setItem('floweroll.sidebar.collapsed',String(collapsed))}catch{}setFocusKey(x=>x+1)},[collapsed]);
 useEffect(()=>{const key=(e:KeyboardEvent)=>{if(e.key==='Escape'){inspectSeq.current++;setInspect(null);setExpandedInspector(false);setFocus(false);setFocusKey(x=>x+1)}if(e.key==='/'&&e.target instanceof HTMLElement&&!['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName)){e.preventDefault();document.querySelector<HTMLInputElement>('[aria-label="搜索节点"]')?.focus()}};window.addEventListener('keydown',key);return()=>window.removeEventListener('keydown',key)},[]);
 const open=useCallback((value:Inspect)=>{inspectSeq.current++;setInspect(value);setExpandedInspector(false);setCopied(false)},[]);
 const showNode=useCallback((component:Component,span?:Span)=>{
   const records=span?[span]:path?.spans.filter(s=>s.component_id===component.id)||[];
   if(span?.call_number){manualCall.current=true;setCallNumber(span.call_number);setDetail(null)}
   if(span?.kind==='model_call'&&typeof span.capture_id==='string'){manualObservation.current=true;setObservationCallId(span.capture_id);setObservationModel(null)}
   const token=++inspectSeq.current;setCopied(false);setInspect({title:component.name,value:{component,records},source:component.source,note:'源码是当前工作区版本；本次执行证据单独列出。'});
   get<Component>(`/api/components/${encodeURIComponent(component.id)}`).then(value=>{if(inspectSeq.current===token)setInspect({title:component.name,value:{component:value,records},source:value.source,note:'源码是当前工作区版本，不代表历史进程所加载的版本。'})}).catch(()=>{});
 },[path]);
 const showEdge=useCallback((edge:Link)=>{if(!edge)return;const ids=new Set([edge.source,edge.target]);
   const records=path?.spans.filter(s=>ids.has(s.id)||ids.has(s.component_id))||[];
   open({title:`${edge.source} → ${edge.target}`,value:{relationship:edge,endpoint_records:records},note:edge.evidence==='source_defined'?'这是源码声明关系；没有传输快照时不能证明本次经过。':'这是持久记录关联，不是抓包结果。实际已采集的数据见两端记录。'});
 },[open,path]);
 const call=path?.planner_calls.find(c=>c.call_number===callNumber);
 const memories=detail?.context?.runtime_context?.relevant_memories;
 const prompt=detail?.system_prompt;
 const response=detail?.model_response;
 const selectedItems=navTab==='tasks'?tasks.filter(t=>(t.goal+' '+t.id).toLowerCase().includes(navQuery.toLowerCase())):observations.filter(o=>((o.title||o.preset_label)+' '+o.id).toLowerCase().includes(navQuery.toLowerCase()));
 const summary=path?.summary;
 const pathSequence=path?chronological(path.spans.filter(span=>span.id==='task'||span.component_id==='planner.graph'||span.id.startsWith('action:')||span.component_id==='execution.runtime'||span.kind==='work_unit_attempt'||span.kind==='model_call')):[];
 const timelineSpans=path?chronological(path.spans):[];
 const visiblePathSequence=pathSequence.slice(0,10);
 const metrics=selection.kind==='observation'&&summary?[
   ['记录跨度',millis(summary.elapsed_ms),'从建立到最近持久更新，不是模型执行时间'],['事件',count(summary.event_count),'会话全部持久事件'],['阶段纪要',count(summary.checkpoint_count),'不是模型调用次数'],['最终纪要',count(summary.final_count),'结果记录数量'],['问答',count(summary.question_count),'已记录的问题'],['已报告 Token',count(summary.reported_tokens_only),'只累计已采集调用的 usage；缺失不当零'],['模型耗时累计',millis(summary.model_ms_sum),'只累计已采集模型请求'],['已采集模型调用',count(summary.captured_model_calls),'不把纪要数量当模型调用次数']
 ]:summary?[
   ['任务跨度',millis(summary.elapsed_ms),'包含暂停、等待和恢复'],['Planner',count(summary.planner_calls),'按唯一 call_number 统计'],['Action / 尝试',`${count(summary.actions)} / ${count(summary.tool_attempts)}`,'规划的 Action 与真实执行 Attempt 分开'],['Work Unit',count(summary.work_units),'未配置 / 未记录时显示 —'],
   ['已报告 Token',count(summary.reported_tokens_only),`${count(summary.reported_usage_calls)} / ${count(summary.planner_calls)} 次有 usage；缺失不算零`],['模型耗时累计',millis(summary.model_ms_sum),`${count(summary.model_timed_calls)} 次有计时；不是任务墙钟时间`],['重试',count(summary.retry_count),'已记录的 Planner 等待、额外执行尝试和 provider 重试']
 ]:[];
 const requestTabs=selection.kind==='task'?[['messages','用户消息'],['memory','Memory'],['system_prompt','System Prompt'],['context','完整上下文'],['tools','工具集'],['wire_request','原始请求'],['model_response','模型结果'],['decision','决策与采纳'],['contract_check','结构检查']]:selection.kind==='observation'?[['system_prompt','System Prompt'],['context','观察上下文'],['wire_request','原始请求'],['model_response','模型结果']]:[];
 const taskContext=detail?.context as Record<string,any>|undefined;
 const taskMessages=selection.kind==='task'&&taskContext?[{id:'initial',label:'首条用户消息',source:taskContext.runtime_context?.invocation_source||'来源未记录',at:null,text:taskContext.task?.raw_goal},...((Array.isArray(taskContext.user_turns)?taskContext.user_turns:[]).map((turn:any,index:number)=>({id:String(turn.event_id||`turn-${index}`),label:`后续用户消息 ${index+1}`,source:turn.reply_context?'回复 / 选择':'用户追加',at:turn.received_at||null,text:turn.content?.text??turn.content})))] : [];
 const wireRequest=(selection.kind==='task'?detail?.wire_request:observationModel?.wire_request) as Record<string,any>|undefined;
 const wireMessages=Array.isArray(wireRequest?.messages)?wireRequest!.messages.map((message:any,index:number)=>({id:`wire-${index}`,role:String(message?.role||'unknown'),content:message?.content})):[];
 const requestPayload=selection.kind==='task'?{
   messages:taskMessages,memory:{retrieved_count:call?.retrieved_memories,injected_count:call?.injected_memories,actually_injected:memories},
   system_prompt:prompt,context:detail?.context,tools:detail?.tools,wire_request:detail?.wire_request,model_response:response,decision:{model_decision:response,runtime_outcome:call?.outcome,note:'模型建议与 Runtime 提交分开；已提交不等于外部效果已完成。'},contract_check:detail?.contract_check
 }:selection.kind==='observation'?{system_prompt:observationModel?.system_prompt,context:observationModel?.context,wire_request:observationModel?.wire_request,model_response:observationModel?.model_response}:{};
 const requestValue=(requestPayload as Record<string,unknown>)[requestTab];
 const captureOmitted=selection.kind==='task'?detail?.metadata?.content_omitted:observationModel?.content_omitted;
 const captureState=selection.kind==='task'?(!detail?'正在读取':captureOmitted?`采集省略：${captureOmitted}`:detail.available?'完整采集':'完整请求未采集'):(!observationModel?'正在读取':captureOmitted?`采集省略：${captureOmitted}`:observationModel.available?'完整采集':'完整请求未采集');
 const copyValue=useCallback(async(value:unknown,key:string)=>{if(value==null)return;try{await navigator.clipboard.writeText(text(value));setRequestCopied(key);setTimeout(()=>setRequestCopied(current=>current===key?null:current),1400)}catch{setRequestCopied(null)}},[]);
 const selectPlanner=useCallback((number:number)=>{manualCall.current=true;if(number!==callNumber){setCallNumber(number);setDetail(null)}setRequestCopied(null);inspectSeq.current++;setInspect(null);setExpandedInspector(false)},[callNumber]);
 const jumpRequestTab=useCallback((tab:string)=>{setRequestTab(tab);setTimeout(()=>document.querySelector<HTMLElement>('[aria-label="请求检查器"]')?.scrollIntoView({behavior:'smooth',block:'center'}),0)},[]);
 const cards=selection.kind==='task'?[
   {title:'Memory',meta:`${count(call?.retrieved_memories)} 检索 → ${count(call?.injected_memories)} 注入`,preview:Array.isArray(memories)&&memories.length?String(memories[0].memory||text(memories[0])):call?.injected_memories===0?'本次请求未注入长期记忆':'检索 / 注入证据待查看',value:{retrieved_count:call?.retrieved_memories,injected_count:call?.injected_memories,actually_injected:memories}},
   {title:'System Prompt',meta:prompt?`${bytes(size(prompt))} · ${detail?.prompt_matches_current?'与源码一致':'版本有差异'}`:'未采集',preview:prompt||'不使用当前模板补造历史 Prompt',value:prompt},
   {title:'完整上下文',meta:detail?.context?bytes(size(detail.context)):'未采集',preview:detail?.context?Object.keys(detail.context).join(' · '):'实际 DecisionContext',value:detail?.context},
   {title:'原始请求',meta:call?.captured?`${bytes(call.request_bytes)} · 已捕获`:'未采集',preview:call?.model||'适配器处理后、发送前的请求体',value:detail?.wire_request},
   {title:'模型结果',meta:response?`${bytes(size(response))} · ${detail?.contract_check?.status==='pass'?'结构通过':detail?.contract_check?.status==='fail'?'结构不通过':'未校验'}`:'未采集',preview:response?text(response):'模型返回的可见内容',value:response},
   {title:'决策与采纳',meta:call?statusLabel(call.outcome):'—',preview:response?.decision_type?`${response.decision_type}${response?.action?.capability?' → '+response.action.capability:''}`:'模型建议与 Runtime 提交分开',value:{model_decision:response,runtime_outcome:call?.outcome,note:'已提交仅表示 Runtime 有提交事件；最终执行结果以 Action / Task 记录为准。'}}
 ]:selection.kind==='observation'?[
   {title:'System Prompt',meta:observationModel?.system_prompt?`${bytes(size(observationModel.system_prompt))} · ${observationModel.prompt_matches_current===true?'与源码一致':observationModel.prompt_matches_current===false?'版本有差异':'版本未知'}`:'未采集',preview:observationModel?.system_prompt||'缺少历史快照，不用当前 Prompt 补造',value:observationModel?.system_prompt},
   {title:'观察上下文',meta:observationModel?.context?bytes(size(observationModel.context)):'证据记录',preview:observationModel?.context?'实际发送的事件、先前摘要、提问及图片内容':`${count(summary?.event_count)} 条事件 · 只展示已持久记录`,value:observationModel?.context||{sources:(path?.detail?.stats as any)?.source_stats,analysis:path?.detail?.analysis,timeline:path?.detail?.timeline}},
   {title:'原始请求',meta:observationModel?.available?`${bytes(observationModel.request_bytes)} · 已捕获`:'未采集',preview:observationModel?.model||'模型调用完成后可查看发送前的请求体',value:observationModel?.wire_request},
   {title:'模型结果',meta:observationModel?statusLabel(observationModel.outcome||observationModel.state):'未采集',preview:observationModel?.model_response?text(observationModel.model_response):'不把纪要回填成历史模型响应',value:observationModel?.model_response},
   {title:'阶段 / 最终纪要',meta:count(summary?.checkpoint_count)+' / '+count(summary?.final_count),preview:'本会话已持久保存的整理结果',value:path?.detail?.notes},
   {title:'观察问答',meta:count(summary?.question_count)+' 个问题',preview:'基于已采集证据的回答',value:path?.detail?.questions}
 ]:[];
 return <div className={`app ${collapsed?'nav-collapsed':''} ${focus?'focus-mode':''}`}>
   <aside className="sidebar" aria-label="导航栏">
     <div className="brand"><div className="brand-symbol">卷</div><div className="brand-name"><b>花卷</b><span>DEVELOPER OBSERVATORY</span></div><button className="collapse-button" aria-label={collapsed?'展开导航':'收起导航'} title={collapsed?'展开导航':'收起导航'} onClick={()=>setCollapsed(!collapsed)}>{collapsed?'›':'‹'}</button></div>
     <button className={`overall-button ${selection.kind==='overall'?'selected':''}`} onClick={()=>choose({kind:'overall'})}><span>◈</span><span className="nav-copy">系统全景<small>架构与运行证据</small></span></button>
     {!collapsed&&<><div className="nav-tabs"><button className={navTab==='tasks'?'selected':''} onClick={()=>setNavTab('tasks')}>任务 <span>{tasks.length}</span></button><button className={navTab==='observations'?'selected':''} onClick={()=>setNavTab('observations')}>观察 <span>{observations.length}</span></button></div>
       <input className="nav-search" aria-label="搜索任务" placeholder="查找任务或观察记录" value={navQuery} onChange={e=>setNavQuery(e.target.value)}/>
       <div className="record-list">{selectedItems.map(item=>{const isTask='goal' in item;const kind=isTask?'task':'observation';const title=isTask?item.goal:item.title||item.preset_label;return <button key={item.id} className={`record ${selection.kind===kind&&selectionId===item.id?'selected':''}`} onClick={()=>choose({kind,id:item.id})}>
           <div className="record-top"><span className={`dot ${item.status}`}/><span>{statusLabel(item.status)}</span><time>{new Date(item.updated_at).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'})}</time></div>
           <strong>{title}</strong><small>{isTask?`Planner ${count(item.planner_calls)} · Action ${count(item.action_count)}`:`${item.event_count} 条证据`}<code>{item.id.slice(0,6)}</code></small></button>})}
         {!selectedItems.length&&<div className="empty-state">暂无匹配记录</div>}</div></>}
     {collapsed&&<div className="rail-buttons"><button aria-label="打开任务列表" title="任务" onClick={()=>{setNavTab('tasks');setCollapsed(false)}}>▤</button><button aria-label="打开观察列表" title="观察" onClick={()=>{setNavTab('observations');setCollapsed(false)}}>◉</button></div>}
     <div className="sidebar-footer"><span className="dot active"/><span className="nav-copy">只读 · 不执行模型或工具</span></div>
   </aside>
   <main className="workspace">
     <header className="workspace-header"><div className="header-title"><span className="eyebrow">{selection.kind==='overall'?'SYSTEM MAP':selection.kind==='task'?'TASK WORKSPACE':'OBSERVATION WORKSPACE'}</span><h1>{selection.kind==='overall'?'小卷的系统地图':path?.goal||'正在读取记录…'}</h1><div className="header-note">{selection.kind==='overall'?`当前源码 · ${topology?.nodes.length||'—'} 个定义 · 运行统计：最近 ${topology?.scope?.task_count??'—'} 个任务`:`${selectionId.slice(0,8)} · ${statusLabel(summary?.task_status)} · ${summary?.runtime_phase||'状态待读取'}`}</div></div>
       <div className="header-actions"><span className="live-badge"><i/>只读工作台</span><button className={auto?'selected':''} title="页面隐藏时暂停轮询" onClick={()=>setAuto(!auto)}>{auto?'自动刷新':'刷新已暂停'}</button><button aria-label="刷新数据" onClick={()=>setRefresh(x=>x+1)}>刷新</button><button aria-label={focus?'退出拓扑专注':'专注拓扑'} onClick={()=>{setTopologyOpen(true);setFocus(!focus);setFocusKey(x=>x+1)}}>{focus?'退出拓扑专注':'专注拓扑'}</button>{status?.langfuse_url&&<a href={status.langfuse_url} target="_blank" rel="noreferrer">Langfuse ↗</a>}</div></header>
     {(error||pathError)&&<div className="error-bar" role="alert">{pathError||error}。保留最后成功读取的画面。<button onClick={()=>setRefresh(x=>x+1)}>重试读取</button></div>}
     {!!metrics.length&&<div className="metrics" aria-label="任务关键指标">{metrics.map(([label,value,note])=><div className="metric" key={label} title={note}><span>{label}</span><strong>{value}</strong>{label==='已报告 Token'&&<small>{count(summary?.reported_usage_calls)} / {count(summary?.planner_calls)} 次已报告</small>}</div>)}</div>}
     <div className="detail-toolbar">
       <span className="detail-toolbar-title">{selection.kind==='overall'?'系统概览':selection.kind==='task'?'任务详情':'观察详情'}</span>
       {!!path?.planner_calls.length&&<select aria-label="选择 Planner 调用" value={callNumber??''} onChange={e=>selectPlanner(Number(e.target.value))}>{path.planner_calls.map(c=><option key={c.call_number} value={c.call_number}>Planner #{c.call_number} · {statusLabel(c.outcome)}</option>)}</select>}
       {!!path?.model_calls?.length&&<select aria-label="选择观察模型调用" value={observationCallId??''} onChange={e=>{manualObservation.current=true;if(e.target.value!==observationCallId){setObservationCallId(e.target.value);setObservationModel(null)}}}>{path.model_calls.map(c=><option key={c.capture_id} value={c.capture_id}>{modelOperation(c.operation)} · {c.started_at?new Date(c.started_at).toLocaleTimeString('zh-CN'):c.capture_id.slice(0,6)} · {statusLabel(c.outcome||c.state)}</option>)}</select>}
       {!!summary?.timed_work_unit_attempts&&<button onClick={()=>open({title:'工作项执行时序',value:{captured_attempts:path?.spans.filter(s=>s.kind==='work_unit_attempt'),overlaps:path?.parallel_evidence},note:'重叠只比较同一进程、同一批次的单调计时。缺失计时不推断为串行。'})}>工作项时序 · {count(summary.parallel_overlaps)} 组重叠</button>}
       {!!path&&<button onClick={()=>setShelf(!shelf)}>{shelf?'收起上下文':'展开上下文'}</button>}
       <button className="coverage-button" onClick={()=>open({title:'证据范围与限制',value:{coverage:path?.coverage,limits:path?.limitations||topology?.limitations,scope:topology?.scope,truncated:path?.truncated},note:'缺少采集不是执行失败；不能把声明路径当成真实经过。'})}>证据范围</button>{loading&&<span className="subtle">同步中</span>}
     </div>
     {shelf&&cards.length>0&&<section className="context-shelf" aria-label="模型上下文速览">{cards.map(card=>{const tab=selection.kind==='task'?({'Memory':'memory','System Prompt':'system_prompt','完整上下文':'context','原始请求':'wire_request','模型结果':'model_response','决策与采纳':'decision'} as Record<string,string>)[card.title]:({'System Prompt':'system_prompt','观察上下文':'context','原始请求':'wire_request','模型结果':'model_response'} as Record<string,string>)[card.title];return <button className={`context-card ${tab&&requestTab===tab?'selected':''}`} key={card.title} onClick={()=>tab?jumpRequestTab(tab):open({title:card.title,value:card.value,call:callNumber??undefined,note:selection.kind==='task'?detail?.note:observationModel?.note||'观察数据独立于任务 Planner。'})}><span>{card.title}<b>{tab?'↓':'↗'}</b></span><strong>{card.meta}</strong><small>{card.preview}</small></button>})}</section>}
     {callError&&<div className="error-bar">上下文读取失败：{callError}</div>}
     {path&&<section className="main-detail-workspace" aria-label="主要任务详情">
       {mode==='execution'&&<section className="path-summary primary-path-summary" aria-label="本次执行主线"><span className="path-summary-title">本次执行顺序<small>点 Planner 可直接切换右侧请求检查器</small></span><div className="path-summary-steps">{visiblePathSequence.map((span,index)=>{const content=<><span className="path-step-index">{span.started_at?String(index+1).padStart(2,'0'):'?'}</span><span className="path-step-copy"><b>{span.id==='task'?'Task':span.name}</b><small>{clock(span.started_at)} · {statusLabel(span.status)}{span.duration_ms!=null?' · '+millis(span.duration_ms):''}</small></span></>;return <span className="path-step-wrap" key={span.id}>{index>0&&<i>→</i>}{span.call_number?<button className={`path-step ${span.status} ${span.call_number===callNumber?'selected':''}`} onClick={()=>selectPlanner(span.call_number!)}>{content}</button>:<span className={`path-step ${span.status}`}>{content}</span>}</span>})}{pathSequence.length>visiblePathSequence.length&&<span className="path-more">+{pathSequence.length-visiblePathSequence.length}</span>}</div></section>}
       <div className={`detail-grid ${requestExpanded?'request-expanded':''}`}>
         <section className="primary-timeline" aria-label="执行记录"><div className="timeline-head"><strong>{selection.kind==='task'?'执行记录':'观察记录'}</strong><span>{selection.kind==='task'?'点 Planner / 模型步骤直接切换右侧检查器 · ':''}严格按已记录开始时间排序 · {path.spans.length} 条{path.truncated?' · 已截取':''}</span></div><div className="timeline-rows">{timelineSpans.map((span,index)=><div className={`timeline-record ${span.call_number===callNumber?'call-selected':''}`} key={span.id}><button className="timeline-select" onClick={()=>span.call_number?selectPlanner(span.call_number):open({title:span.name,value:span,note:'按持久记录 / 捕获数据展示；列表序号表示开始时间顺序，不代表因果。'})}><span className="timeline-order">{span.started_at?`#${String(index+1).padStart(2,'0')}`:'?'}</span><time>{clock(span.started_at)}</time><strong>{span.name}</strong><span>{statusLabel(span.status)}</span><span>{millis(span.duration_ms)}</span></button><button className="timeline-detail" aria-label={`查看 ${span.name} 记录详情`} onClick={()=>open({title:span.name,value:span,note:'原始持久记录 / 捕获数据；Planner 选择不会被此详情改变。'})}>详情</button></div>)}</div></section>
         <section className={`request-inspector-main ${requestExpanded?'expanded':''}`} aria-label="请求检查器">
           <div className="request-inspector-head"><div><strong>请求检查器</strong><small>{selection.kind==='task'?`Planner #${callNumber??'—'}${call?.model?' · '+call.model:''}`:observationModel?`${modelOperation(observationModel.operation)}${observationModel.model?' · '+observationModel.model:''}`:'选择一次模型调用'} · {captureState}</small></div><div className="request-head-actions"><span>{requestValue==null?'未采集':bytes(size(requestValue))}</span><button disabled={requestValue==null} onClick={()=>copyValue(requestValue,'current')}>{requestCopied==='current'?'已复制':'复制当前'}</button><button onClick={()=>setRequestExpanded(!requestExpanded)}>{requestExpanded?'恢复布局':'放大查看'}</button></div></div>
           <div className="request-tabs">{requestTabs.map(([key,label])=><button key={key} className={requestTab===key?'selected':''} onClick={()=>{setRequestTab(key);setRequestCopied(null)}}>{label}</button>)}</div>
           {requestTab==='messages'&&selection.kind==='task'?<div className="copy-message-list">{!detail?<div className="request-empty">正在读取 Planner Context…</div>:taskMessages.length?taskMessages.map(message=><article className="copy-message" key={message.id}><header><div><strong>{message.label}</strong><small>{message.source}{message.at?` · ${clock(message.at)}`:''}</small></div><button onClick={()=>copyValue(message.text,message.id)}>{requestCopied===message.id?'已复制':'复制'}</button></header><p>{message.text==null?'内容未记录':typeof message.text==='string'?message.text:text(message.text)}</p></article>):<div className="request-empty">该 Planner Context 没有记录用户消息。</div>}</div>:requestTab==='wire_request'&&wireMessages.length?<div className="request-payload-stack"><div className="wire-message-strip">{wireMessages.map(message=><article className="wire-message-card" key={message.id}><div><b>{message.role}</b><span>{bytes(size(message.content))}</span></div><p>{typeof message.content==='string'?message.content.slice(0,360):text(message.content).slice(0,360)}{size(message.content)&&Number(size(message.content))>360?'…':''}</p><button onClick={()=>copyValue(message.content,message.id)}>{requestCopied===message.id?'已复制':'复制这条消息'}</button></article>)}</div><div className="raw-request-label"><strong>完整原始请求 JSON</strong><span>下方不做前端截断 · 可滚动查看或复制当前</span></div><pre>{requestValue==null?'没有记录到该内容。':text(requestValue)}</pre></div>:<pre>{requestValue==null?'没有记录到该内容。':text(requestValue)}</pre>}
         </section>
       </div>
     </section>}
     {!path&&selection.kind==='overall'&&<section className="main-overall-note"><strong>系统全景</strong><p>主页面保持简洁；完整系统拓扑放在下方展开区域，需要时再查看。</p></section>}
     <details className="topology-dropdown" open={topologyOpen} onToggle={e=>{const opened=(e.currentTarget as HTMLDetailsElement).open;setTopologyOpen(opened);if(!opened)setFocus(false);if(opened)setTimeout(()=>setFocusKey(x=>x+1),50)}}>
       <summary><span><b>拓扑图</b><small>{path?'查看本次执行与系统组件关系':'查看完整系统组件关系'}</small></span><span className="topology-summary-meta">{topology?.nodes.length||'—'} 个定义{path?` · ${path.spans.length} 条本次记录`:''}<i>⌄</i></span></summary>
       <div className="topology-body">
         <div className="view-toolbar topology-toolbar">{focus&&<button aria-label="退出拓扑专注" onClick={()=>{setFocus(false);setFocusKey(x=>x+1)}}>退出专注 · Esc</button>}<div className="segmented"><button className={mode==='system'?'selected':''} onClick={()=>setMode('system')}>系统拓扑</button><button disabled={!path} className={mode==='execution'?'selected':''} onClick={()=>setMode('execution')}>本次执行</button></div><span className="view-caption">{mode==='system'?'稳定组件 + 本次证据叠加':'节点按已记录开始时间从左到右；粉色连线仍表示记录 ID 关联'}</span></div>
         <div className="topology-canvas">{topology?<Graph topology={topology} path={path} mode={mode} onNode={showNode} onEdge={showEdge} onClear={()=>{inspectSeq.current++;setInspect(null)}} focusKey={focusKey}/>:<div className="welcome-loading"><div className="brand-symbol">卷</div><h2>正在读取系统结构</h2><p>只分析已有源码与执行记录，不启动业务 Runtime。</p></div>}</div>
       </div>
     </details>
     {inspect&&<aside className={`inspector ${expandedInspector?'inspector-expanded':''}`} aria-label="详情检查器"><div className="inspector-header"><div><span className="eyebrow">INSPECTOR{inspect.call?` · PLANNER #${inspect.call}`:''}</span><h2>{inspect.title}</h2></div><button aria-label="扩大详情" onClick={()=>setExpandedInspector(!expandedInspector)}>{expandedInspector?'↙':'↗'}</button><button aria-label="关闭详情" onClick={()=>{inspectSeq.current++;setInspect(null)}}>×</button></div>
       {inspect.note&&<p className="inspector-note">{inspect.note}</p>}
       {inspect.source&&<div className="source-ref"><code>{inspect.source.file}{inspect.source.line?':'+inspect.source.line:''}</code><span>{inspect.source.symbol}</span><small>当前源码 · {inspect.source.sha256?.slice(0,12)||'位置未知'}</small></div>}
       <div className="inspector-actions"><button onClick={async()=>{try{await navigator.clipboard.writeText(text(inspect.value));setCopied(true)}catch{setCopied(false)}}}>{copied?'已复制':'复制内容'}</button><span>{bytes(size(inspect.value))}</span></div>
       <pre tabIndex={0}>{text(inspect.value)}</pre></aside>}
     <footer className="statusbar"><span>{path?'本次记录：'+(path.checked_at?new Date(path.checked_at).toLocaleTimeString('zh-CN'):'—'):'统计范围：最近任务窗口'} · {status?.mode==='local_full'?'完整本机采集':'元数据 / 关闭'}{path?.truncated?' · 记录已截取':''}</span><span>源码 {topology?.source_fingerprint.slice(0,10)||'—'} · 非历史构建快照</span></footer>
   </main>
 </div>
}
