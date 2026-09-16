import { memo,useEffect,useMemo,useRef,useState,useCallback } from 'react';
import { ReactFlow,Background,Controls,MiniMap,Handle,Position,MarkerType,applyNodeChanges,type Node,type Edge,type NodeProps,type NodeChange,type ReactFlowInstance } from '@xyflow/react';
import ELK from 'elkjs/lib/elk-api.js';
import elkWorkerUrl from 'elkjs/lib/elk-worker.min.js?url';
import '@xyflow/react/dist/style.css';
import type {Component,ExecutionPath,Link,Span,Topology} from './types';
import {count,millis,statusLabel} from './api';

type CardData={label:string;subtitle:string;owner:string;zone:string;execution:boolean;active:boolean;dim:boolean;warning:boolean;badge:string;detail?:string;component:Component;span?:Span;expand?:()=>void;expanded?:boolean;children?:number;order?:number;timeLabel?:string;timeKnown?:boolean};
type CardNode=Node<CardData,'component'>;
const Card=memo(({data,selected}:NodeProps<CardNode>)=><div className={`graph-card zone-${data.zone} ${data.owner} ${data.execution?'execution-card':''} ${data.active?'is-active':''} ${data.dim?'is-dim':''} ${selected?'is-selected':''} ${data.warning?'is-warning':''}`}>
  <Handle type="target" position={Position.Left}/><div className="node-kicker"><span className={data.execution?'execution-order':''}>{data.execution?<><b>{data.timeKnown?`#${String(data.order).padStart(2,'0')}`:'?'}</b><time>{data.timeLabel}</time></>:data.zone==='ios'?'iOS 设备':data.zone==='external'?'外部服务':'Host'}</span><span className="node-badge">{data.badge}</span></div>
  <strong title={data.label}>{data.label}</strong>{data.execution&&data.span&&<div className="execution-state"><b>{statusLabel(data.span.status)}</b><em>{millis(data.span.duration_ms)}</em></div>}<div className="node-subtitle" title={data.subtitle}>{data.subtitle}</div>
  {data.detail&&<div className="node-detail" title={data.detail}>{data.detail}</div>}
  <div className="node-footer"><span>{data.span?(data.execution?'点击查看输入 / 输出':`${statusLabel(data.span.status)} · ${millis(data.span.duration_ms)}`):data.active?'本次有记录':data.component.stats?`${count(data.component.stats.calls)} 次 · ${count(data.component.stats.task_count)} 个任务`:'源码定义 · 命中未知'}</span>
    {!!data.children&&<button className="nodrag" aria-label={`${data.expanded?'收起':'展开'} ${data.label}`} onClick={e=>{e.stopPropagation();data.expand?.()}}>{data.expanded?'−':'+'} {data.children}</button>}</div><Handle type="source" position={Position.Right}/>
</div>);
const nodeTypes={component:Card};
const elk=new ELK({workerUrl:elkWorkerUrl});
const SYSTEM_H=120,SYSTEM_W=236,EXECUTION_H=154,EXECUTION_W=292;
const zoneOf=(component:Component)=>component.source?.file?.startsWith('ios/')?'ios':component.id==='model.provider'||component.kind==='provider'?'external':'host';
const spanStart=(span?:Span)=>{if(!span?.started_at)return null;const value=Date.parse(span.started_at);return Number.isFinite(value)?value:null};
const clock=(span?:Span)=>{if(!span?.started_at)return '时间未记录';const date=new Date(span.started_at);if(Number.isNaN(date.getTime()))return '时间未记录';return `${date.toLocaleTimeString('zh-CN',{hour12:false})}.${String(date.getMilliseconds()).padStart(3,'0')}`};
const executionLane=(span?:Span)=>{if(!span)return 1;if(span.component_id==='planner.graph'||span.component_id.startsWith('planner.step:')||span.component_id==='model.provider')return 0;if(span.component_id==='execution.runtime'||span.kind==='work_unit_attempt')return 2;return 1};

export function Graph({topology,path,mode,onNode,onEdge,onClear,focusKey}:{topology:Topology;path:ExecutionPath|null;mode:'system'|'execution';onNode:(c:Component,s?:Span)=>void;onEdge:(e:Link)=>void;onClear:()=>void;focusKey:number}){
 const [expanded,setExpanded]=useState<Set<string>>(new Set());const [query,setQuery]=useState('');const [activeOnly,setActiveOnly]=useState(false);const [showInternal,setShowInternal]=useState(false);
 const [lane,setLane]=useState('all');const [zone,setZone]=useState('all');const [nodes,setNodes]=useState<CardNode[]>([]);const [edges,setEdges]=useState<Edge[]>([]);const [layoutBusy,setLayoutBusy]=useState(false);
 const flow=useRef<ReactFlowInstance<CardNode,Edge>|null>(null);const signature=useRef('');const sequence=useRef(0);const positions=useRef<Record<string,{x:number;y:number}>>({});
 const layoutStorage=mode==='execution'?`floweroll.layout:execution:${path?.id}`:'floweroll.layout:system:v1';
 useEffect(()=>{try{positions.current=JSON.parse(localStorage.getItem(layoutStorage)||'{}')}catch{positions.current={}}signature.current=''},[layoutStorage]);
 const toggle=useCallback((id:string)=>setExpanded(old=>{const next=new Set(old);next.has(id)?next.delete(id):next.add(id);return next}),[]);
 const data=useMemo(()=>{
   const catalog=new Map(topology.nodes.map(n=>[n.id,n]));
   for(const span of path?.spans||[]){if(!catalog.has(span.component_id))catalog.set(span.component_id,{id:span.component_id,name:span.name,lifecycle_owner:path!.kind==='observation'?'observation':'task',kind:'unmapped',parent_id:span.component_id.startsWith('capability:')?'capability.registry':null,evidence:'unmapped_runtime',source:null})}
   const active=new Set(Object.keys(path?.components||{}));const propagated=new Set(active);
   for(const id of active){let n=catalog.get(id);while(n?.parent_id){propagated.add(n.parent_id);n=catalog.get(n.parent_id)}}
   let selected:Component[]=[];let connections:Link[]=[];const instances=new Map<string,Span>();
   if(mode==='execution'&&path){
     const q=query.toLowerCase().trim();
     const visible=path.spans.filter(s=>s.kind!=='event'&&(s.kind!=='observation_record'||!s.parent_id||s.component_id!=='observation.store')).filter(s=>{
       const c=catalog.get(s.component_id)!;const internal=s.component_id.startsWith('planner.step:')||s.component_id==='model.provider';
       return (lane==='all'||c.lifecycle_owner===lane||c.lifecycle_owner==='shared')&&
         (showInternal||!!q||!internal)&&(!q||`${s.name} ${c.name} ${c.source?.file||''} ${s.component_id}`.toLowerCase().includes(q))
     }).slice(0,240);
     selected=visible.map(s=>{instances.set(s.id,s);return {...catalog.get(s.component_id)!,id:s.id,parent_id:null,name:s.name}});
     const ids=new Set(selected.map(n=>n.id));connections=path.edges.filter(e=>ids.has(e.source)&&ids.has(e.target));
   }else{
     const q=query.toLowerCase().trim();
     selected=[...catalog.values()].filter(n=>(lane==='all'||n.lifecycle_owner===lane||n.lifecycle_owner==='shared')&&(zone==='all'||zoneOf(n)===zone)&&(!activeOnly||!path||propagated.has(n.id))&&
       (q?`${n.name} ${n.source?.file||''} ${n.id}`.toLowerCase().includes(q):!n.parent_id||expanded.has(n.parent_id)));
     const ids=new Set(selected.map(n=>n.id));connections=topology.edges.filter(e=>ids.has(e.source)&&ids.has(e.target));
     // Overlay only ID-backed relationships. Never highlight a declared edge merely because both ends ran.
     if(path){const byId=new Map(path.spans.map(s=>[s.id,s]));const joined=new Map<string,Link>();
       for(const edge of path.edges){const a=byId.get(edge.source)?.component_id,b=byId.get(edge.target)?.component_id;
         if(a&&b&&a!==b&&ids.has(a)&&ids.has(b)){const id=`runtime:${a}:${b}:${edge.relation}`;joined.set(id,{...edge,id,source:a,target:b,label:edge.relation==='dependency'?'依赖':'本次记录关联'})}}
       connections.push(...joined.values());}
   }
   const plannerByCall=new Map((path?.planner_calls||[]).map(call=>[call.call_number,call]));
   const visibleOrder=new Map<string,number>();
   if(mode==='execution'){let order=0;[...selected].map((component,index)=>({component,index,span:instances.get(component.id)})).sort((a,b)=>{const at=spanStart(a.span),bt=spanStart(b.span);return at===null&&bt===null?a.index-b.index:at===null?1:bt===null?-1:at-bt||a.index-b.index}).forEach(item=>{if(spanStart(item.span)!==null)visibleOrder.set(item.component.id,++order)})}
   const cards:CardNode[]=selected.map(c=>{const span=instances.get(c.id);const original=span?catalog.get(span.component_id)!:c;
     const children=mode==='system'?[...catalog.values()].filter(n=>n.parent_id===c.id).length:0;const call=span?.call_number?plannerByCall.get(span.call_number):undefined;
     const detail=span&&call?`${call.model||'模型未知'} · ${call.reported_tokens!=null?count(call.reported_tokens)+' token':'Token 未记录'}`:span?.kind==='work_unit_attempt'?`Work Unit · ${String(span.work_unit_id||'')}`:undefined;
     const width=mode==='execution'?EXECUTION_W:SYSTEM_W,height=mode==='execution'?EXECUTION_H:SYSTEM_H;
     return {id:c.id,type:'component',position:{x:0,y:0},width,height,data:{label:c.name,owner:c.lifecycle_owner,zone:zoneOf(original),execution:mode==='execution',component:original,span,
       subtitle:span?(span.component_id==='planner.graph'?'PlannerGraph':original.source?.symbol||span.timing_kind):c.source?.symbol||c.id,detail,active:!!path&&(span?true:propagated.has(c.id)),dim:!!path&&!span&&!propagated.has(c.id),warning:c.evidence==='unmapped_runtime',
       badge:span?(span.component_id==='planner.graph'?'PLANNER':span.kind==='work_unit_attempt'?'UNIT':'TRACE'):c.evidence==='unmapped_runtime'?'未映射':c.kind==='http'?'API':c.kind==='graph_step'?'GRAPH':c.kind==='capability'?'TOOL':'MODULE',
       order:span?visibleOrder.get(c.id):undefined,timeKnown:!!span&&spanStart(span)!==null,timeLabel:span?clock(span):undefined,
       children,expanded:expanded.has(c.id),expand:()=>toggle(c.id)}}});
   return {cards,connections};
 },[topology,path,mode,expanded,toggle,query,lane,zone,activeOnly,showInternal]);
 useEffect(()=>{
   const nextEdges=data.connections.map(e=>({id:e.id,source:e.source,target:e.target,type:'smoothstep',label:e.relation==='contains'||(mode==='system'&&e.evidence==='source_defined')?'':e.label,
     markerEnd:{type:MarkerType.ArrowClosed,width:16,height:16,color:mode==='execution'?'#bd587d':e.evidence==='source_defined'?'#aeb8c4':'#cf7794'},
     data:{record:e},style:{stroke:mode==='execution'?'#bd587d':e.evidence==='source_defined'?'#b8c0ca':'#cf7794',strokeWidth:mode==='execution'?3:e.evidence==='source_defined'?1.2:2.4,strokeDasharray:mode==='system'&&e.evidence==='source_defined'?'5 5':undefined},
     labelStyle:{fill:'#647082',fontSize:10,fontWeight:mode==='execution'?600:400},labelBgStyle:{fill:'#fbfbfe'},labelBgPadding:[4,3] as [number,number]}));
   const key=JSON.stringify([layoutStorage,mode,showInternal,data.cards.map(n=>n.id),nextEdges.map(e=>[e.source,e.target])]);
   setEdges(nextEdges);
   if(key===signature.current){setNodes(old=>data.cards.map(n=>({...n,position:old.find(o=>o.id===n.id)?.position||positions.current[n.id]||n.position,selected:old.find(o=>o.id===n.id)?.selected})));return}
   signature.current=key;const token=++sequence.current;setLayoutBusy(true);
   if(mode==='execution'){
     const laidOut=[...data.cards].sort((a,b)=>(a.data.order??Number.MAX_SAFE_INTEGER)-(b.data.order??Number.MAX_SAFE_INTEGER)).map((node,index)=>({...node,position:{x:70+index*(EXECUTION_W+92),y:116+executionLane(node.data.span)*205}}));
     setNodes(laidOut);setLayoutBusy(false);setTimeout(()=>{const first=laidOut[0];const zoom=.88;if(first)void flow.current?.setViewport({x:76-first.position.x*zoom,y:116-first.position.y*zoom,zoom},{duration:320})},40);return;
   }
   elk.layout({id:'root',layoutOptions:{'elk.algorithm':'layered','elk.direction':'RIGHT','elk.spacing.nodeNode':'42','elk.layered.spacing.nodeNodeBetweenLayers':'85','elk.layered.nodePlacement.strategy':'NETWORK_SIMPLEX'},children:data.cards.map(n=>({id:n.id,width:SYSTEM_W,height:SYSTEM_H})),edges:nextEdges.map(e=>({id:e.id,sources:[e.source],targets:[e.target]}))}).then(graph=>{
     if(sequence.current!==token)return;
     const coords=new Map(graph.children?.map(n=>[n.id,{x:n.x||0,y:n.y||0}])||[]);
     const laidOut=data.cards.map(n=>({...n,position:positions.current[n.id]||coords.get(n.id)||n.position}));
     setNodes(laidOut);setLayoutBusy(false);setTimeout(()=>void flow.current?.fitView({padding:.17,duration:350,maxZoom:.95}),40);
   }).catch(()=>{if(sequence.current!==token)return;setNodes(data.cards.map((n,i)=>({...n,position:positions.current[n.id]||{x:(i%4)*320,y:Math.floor(i/4)*165}})));setLayoutBusy(false)});
 },[data,layoutStorage]);
 useEffect(()=>{setTimeout(()=>{
   if(mode==='execution'){
     const first=nodes[0];const zoom=.88;
     if(first)void flow.current?.setViewport({x:76-first.position.x*zoom,y:108-first.position.y*zoom,zoom},{duration:260});
   }else void flow.current?.fitView({duration:300,padding:.17,maxZoom:.95});
 },60)},[focusKey,mode]);
 const onChange=useCallback((changes:NodeChange<CardNode>[])=>setNodes(old=>applyNodeChanges(changes,old)),[]);
 const savePosition=useCallback((_e:unknown,node:CardNode)=>{if(mode==='execution')return;positions.current[node.id]=node.position;try{localStorage.setItem(layoutStorage,JSON.stringify(positions.current))}catch{}},[layoutStorage,mode]);
 const focusExecutionStart=useCallback(()=>{const first=nodes[0];const zoom=.88;if(first)void flow.current?.setViewport({x:76-first.position.x*zoom,y:116-first.position.y*zoom,zoom},{duration:280})},[nodes]);
 return <section className={`graph-area ${mode}-view`} aria-label="系统拓扑画布">
   <div className="graph-tools"><input aria-label="搜索节点" placeholder="搜索节点 / 接口 / 源码…" value={query} onChange={e=>setQuery(e.target.value)}/>
     <select aria-label="筛选生命周期" value={lane} onChange={e=>setLane(e.target.value)}><option value="all">所有生命周期</option><option value="task">任务模式</option><option value="observation">观察模式</option></select>
     {mode==='system'&&<select aria-label="筛选系统区域" value={zone} onChange={e=>setZone(e.target.value)}><option value="all">iOS / Host / External</option><option value="ios">iOS 设备</option><option value="host">Host</option><option value="external">外部服务</option></select>}
     {mode==='system'&&path&&<button className={activeOnly?'chosen':''} onClick={()=>setActiveOnly(!activeOnly)}>仅看有记录</button>}
     {mode==='execution'&&<button className={showInternal?'chosen':''} onClick={()=>setShowInternal(!showInternal)}>{showInternal?'收起 Planner 内部':'展开 Planner 内部'}</button>}
     {mode==='execution'?<button onClick={focusExecutionStart}>回到时间起点</button>:<button onClick={()=>{positions.current={};localStorage.removeItem(layoutStorage);signature.current='';setExpanded(new Set(expanded))}}>重新排版</button>}
     <span className="graph-size">{mode==='execution'?'开始时间从左到右 · ':''}{nodes.length} 节点 / {edges.length} 关系</span>
   </div>
   {mode==='system'&&<div className="system-zone-hint" aria-hidden="true"><span>iOS 设备</span><span>Host</span><span>External</span></div>}
   {mode==='execution'&&<div className="execution-time-hint" aria-hidden="true"><span>早</span><i/><b>开始时间 →</b><i/><span>晚</span></div>}
   <ReactFlow<CardNode,Edge> nodes={nodes} edges={edges} nodeTypes={nodeTypes} onInit={instance=>{flow.current=instance}} onNodesChange={onChange} onNodeDragStop={savePosition}
     onNodeClick={(_e,n)=>onNode(n.data.component,n.data.span)} onEdgeClick={(_e,e)=>onEdge(e.data?.record as Link)} onPaneClick={onClear}
     nodesConnectable={false} nodesDraggable={mode==='system'} edgesReconnectable={false} deleteKeyCode={null} minZoom={.08} maxZoom={2} onlyRenderVisibleElements
     proOptions={{hideAttribution:false}}><Background gap={22} size={1}/><Controls showInteractive={false}/><MiniMap pannable zoomable nodeColor={n=>n.data.owner==='observation'?'#90b6b4':n.data.owner==='task'?'#deb0c1':'#a5b6cf'}/></ReactFlow>
   {layoutBusy&&<div className="graph-loading">正在整理节点布局…</div>}
   {!nodes.length&&!layoutBusy&&<div className="graph-loading">没有匹配节点，调整筛选即可。</div>}
   <div className="graph-legend">{mode==='execution'?<><span><i className="legend-solid"/> 粉色连线：记录 ID 关联</span><span>卡片 # 编号：开始时间顺序</span><span>时间未知的节点统一置后 · 编号不代表因果</span></>:<><span><i className="legend-dashed"/> 源码声明</span><span><i className="legend-solid"/> 本次记录关联</span><span>拖动仅改变布局，不改变执行流程</span></>}</div>
 </section>
}
