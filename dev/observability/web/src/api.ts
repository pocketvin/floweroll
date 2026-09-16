export async function get<T>(path:string, signal?:AbortSignal):Promise<T>{
  const response=await fetch(path,{headers:{'X-Floweroll-Console':'1'},cache:'no-store',signal});
  if(!response.ok){let reason='';try{reason=(await response.json()).error||''}catch{}throw new Error(`${response.status} ${reason||'读取失败'}`)}
  return response.json() as Promise<T>;
}
export const count=(value:unknown)=>typeof value==='number'?value.toLocaleString('zh-CN'):'—';
export function millis(value:unknown):string {if(typeof value!=='number')return '未记录';if(value<1000)return `${value.toFixed(value<10?1:0)} ms`;if(value<60000)return `${(value/1000).toFixed(1)} s`;if(value<3600000)return `${(value/60000).toFixed(1)} min`;return `${(value/3600000).toFixed(1)} h`}
export function bytes(value:unknown):string{if(typeof value!=='number')return '未记录';return value<1024?`${value} B`:`${(value/1024).toFixed(1)} KB`}
export function text(value:unknown):string {if(value===undefined||value===null)return '未采集 / 不可用';return typeof value==='string'?value:JSON.stringify(value,null,2)}
export const size=(value:unknown)=>value==null?null:new TextEncoder().encode(typeof value==='string'?value:JSON.stringify(value)).byteLength;
const labels:Record<string,string>={active:'进行中',completed:'已完成',failed:'失败',cancelled:'已取消',blocked:'已暂停',waiting:'等待中',recording:'采集中',finalizing:'整理中',analysis_failed:'整理失败',in_flight:'进行中',committed:'已采纳',stale:'已过期',response_received:'已返回',recorded:'有记录',result_recorded:'有结果',success:'成功',succeeded:'成功',SUCCESS:'成功',unknown:'未知',working:'处理中',pending:'待执行',model_validated:'模型校验通过',verified:'核验已采纳',superseded:'结果未采纳',finished:'已结束'};
export const statusLabel=(v:unknown)=>typeof v==='string'?labels[v]||v:'未知';

export const modelOperation=(op:string)=>({'observation.vision':'屏幕视觉','observation.summary':'阶段整理','observation.final':'最终整理','observation.question':'观察问答'}[op]||op);
