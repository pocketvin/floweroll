export type Json = unknown;
export interface Source { file:string; symbol:string; line:number|null; available:boolean; sha256:string|null; basis:string }
export interface Component { id:string; name:string; lifecycle_owner:string; kind:string; parent_id?:string|null; evidence:string; source?:Source|null; stats?:{calls:number;task_count:number;errors:number;last_seen:string|null}|null; [key:string]:unknown }
export interface Link { id:string;source:string;target:string;relation:string;evidence:string;label?:string }
export interface Topology {schema_version:number;nodes:Component[];edges:Link[];source_fingerprint:string;limitations:string[];scope?:{kind:string;task_count?:number;limit?:number;note?:string};checked_at:string}
export interface Span {id:string;component_id:string;name:string;parent_id?:string|null;started_at:string|null;ended_at:string|null;duration_ms:number|null;status:string;kind:string;evidence:string;timing_kind:string;call_number?:number;payload?:Json;[key:string]:unknown}
export interface PlannerCall {call_number:number;outcome:string;model:string|null;reported_tokens:number|null;prompt_tokens:number|null;completion_tokens:number|null;model_ms:number|null;duration_ms:number|null;captured:boolean;request_bytes:number|null;retrieved_memories:number|null;injected_memories:number|null;prompt_sha256:string|null}
export interface ExecutionPath {kind:'task'|'observation';id:string;trace_id:string;goal:string;spans:Span[];edges:Link[];components:Record<string,{records:number;errors:number}>;planner_calls:PlannerCall[];summary:Record<string,string|number|null>;limitations:string[];truncated:boolean;checked_at:string;detail?:Record<string,unknown>;coverage:Record<string,unknown>;model_calls?:ModelCall[];parallel_evidence?:Record<string,unknown>[]}
export interface Task {id:string;goal:string;status:string;updated_at:string;planner_calls?:number;action_count?:number}
export interface Observation {id:string;title?:string|null;preset_label:string;status:string;event_count:number;updated_at:string}
export interface CallDetail {call_number:number;available:boolean;note:string;metadata:Record<string,unknown>;metrics:Record<string,unknown>[];system_prompt?:string;context?:Record<string,any>;wire_request?:Record<string,any>;tools?:Record<string,any>;model_response?:any;contract_check?:{status:string;note:string};prompt_matches_current?:boolean;prompt_diff?:string}
export interface Status {mode:string;langfuse_url:string;prompts_url?:string;export?:{status:string};read_only:boolean}
export type Selection={kind:'overall'}|{kind:'task'|'observation';id:string};
export interface Inspect {title:string;value:unknown;source?:Source|null;call?:number;note?:string}

export interface ModelCall {capture_id:string;operation:string;started_at:string|null;ended_at:string|null;duration_ms:number|null;model_ms:number|null;model:string|null;state:string;outcome:string|null;captured:boolean;request_bytes:number|null;reported_tokens:number|null;prompt_tokens:number|null;completion_tokens:number|null;content_omitted?:string|null}
export interface ModelDetail extends ModelCall {available:boolean;note:string;system_prompt?:string;context?:unknown;wire_request?:unknown;model_response?:unknown;validated_output?:unknown;prompt_matches_current?:boolean|null}
