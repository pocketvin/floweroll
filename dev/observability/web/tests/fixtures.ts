/** Synthetic browser contracts only: no personal Tasks, runtime DB or model calls. */
import type { Page } from '@playwright/test';
import type { CallDetail, Component, ExecutionPath, ModelDetail, Span, Topology } from '../src/types';

export const taskId = '44444444-4444-4444-8444-444444444444';
const observationId = '55555555-5555-4555-8555-555555555555';
const captureId = '66666666-6666-4666-8666-666666666666';
const stamp = (second: number) => `2026-09-16T03:00:${String(second).padStart(2, '0')}Z`;
export const requestEndMarker = 'SYNTHETIC_REQUEST_END_NOT_TRUNCATED';

function component(id: string, name: string, file: string, kind = 'module', parent_id: string | null = null): Component {
  return { id, name, kind, parent_id, lifecycle_owner: id.startsWith('observation') ? 'observation' : 'task',
    evidence: 'test_fixture', source: { file, symbol: name, line: 1, available: true, sha256: 'test-only', basis: 'test_fixture' } };
}
const nodes = [
  component('task.runtime', 'Task Runtime', 'host/floweroll_host/task_runtime.py'),
  component('planner.graph', 'Planner 决策', 'host/floweroll_host/planner_graph.py'),
  component('planner.step:build_context', 'build_context', 'host/floweroll_host/planner_graph.py', 'graph_step', 'planner.graph'),
  component('model.provider', '测试模型服务', 'host/floweroll_host/openai_compatible_chat_adapter.py', 'provider'),
  component('ios.input', 'iOS 输入', 'ios/Floweroll/App/Home/HomeView.swift'),
  component('observation.service', '观察服务', 'host/floweroll_host/observation_service.py'),
];
const topology: Topology = {
  schema_version: 1, nodes, source_fingerprint: 'synthetic-topology',
  edges: [{ id: 'declaration', source: 'task.runtime', target: 'planner.graph', relation: 'calls', evidence: 'source_defined' }],
  scope: { kind: 'test_fixture', task_count: 1, note: 'Synthetic test only' },
  limitations: ['固定测试数据，不代表线上执行记录'], checked_at: stamp(20),
};
function span(id: string, component_id: string, name: string, second: number, kind = 'generation', call_number?: number): Span {
  return { id, component_id, name, started_at: stamp(second), ended_at: stamp(second + 1), duration_ms: 1000,
    status: 'committed', kind, evidence: 'test_fixture', timing_kind: 'test_fixture', call_number };
}
const taskPath: ExecutionPath = {
  kind: 'task', id: taskId, trace_id: taskId, goal: '固定测试任务：整理一份示例资料',
  spans: [span('task', 'task.runtime', 'Task', 0, 'task'),
    ...Array.from({ length: 5 }, (_, i) => span(`planner:${i + 1}`, 'planner.graph', `Planner #${i + 1}`, i * 2 + 1, 'generation', i + 1)),
    span('step:1', 'planner.step:build_context', 'build_context', 1, 'graph_step', 1)],
  edges: [{ id: 'record', source: 'task', target: 'planner:1', relation: 'parent', evidence: 'test_fixture' }],
  components: { 'task.runtime': { records: 1, errors: 0 }, 'planner.graph': { records: 5, errors: 0 } },
  planner_calls: Array.from({ length: 5 }, (_, i) => ({ call_number: i + 1, outcome: 'committed', model: 'fixture-only',
    reported_tokens: 25, prompt_tokens: 20, completion_tokens: 5, model_ms: 800, duration_ms: 1000,
    captured: true, request_bytes: 60000, retrieved_memories: 1, injected_memories: 1, prompt_sha256: 'test-only' })),
  summary: { task_status: 'completed', elapsed_ms: 11000, planner_calls: 5, actions: 0, tool_attempts: 0,
    work_units: 0, reported_tokens_only: 125, reported_usage_calls: 5, model_ms_sum: 4000, model_timed_calls: 5, retry_count: 0 },
  limitations: ['固定测试数据'], truncated: false, coverage: { source: 'test_fixture' }, checked_at: stamp(20),
};
function callDetail(number: number): CallDetail {
  const context = { task: { raw_goal: taskPath.goal }, runtime_context: { invocation_source: 'test_fixture',
    relevant_memories: [{ memory: '固定测试记忆：偏好简洁的输出', memory_id: 'fixture-memory', score: 0.9 }] },
    user_turns: [{ event_id: 'fixture-turn', received_at: stamp(10), content: { text: '继续安排示例资料' } }],
    observations: [{ text: '仅用于验证完整请求显示。'.repeat(2000) + requestEndMarker }] };
  const system = `FIXTURE_SYSTEM_PROMPT_${number}`;
  return { call_number: number, available: true, note: '固定浏览器测试夹具', metadata: {}, metrics: [],
    system_prompt: system, context, tools: { visible: ['test.only'], schemas: [] },
    wire_request: { model: 'fixture-only', messages: [{ role: 'system', content: system },
      { role: 'user', content: JSON.stringify({ decision_context: context }) }] },
    model_response: { decision_type: 'COMPLETE', final_answer: '仅测试，不调用工具', action: null },
    prompt_matches_current: true, contract_check: { status: 'pass', note: 'test_fixture' } };
}
const observationCall: ModelDetail = { capture_id: captureId, operation: 'observation.summary',
  started_at: stamp(0), ended_at: stamp(1), duration_ms: 1000, model_ms: 900, model: 'fixture-only',
  state: 'finished', outcome: 'model_validated', captured: true, request_bytes: 100,
  reported_tokens: 25, prompt_tokens: 20, completion_tokens: 5, available: true,
  note: '固定测试夹具', system_prompt: 'FIXTURE_OBSERVATION_PROMPT', context: { events: [] },
  wire_request: { model: 'fixture-only' }, model_response: { summary: '固定摘要' }, prompt_matches_current: true };
const observationPath: ExecutionPath = { kind: 'observation', id: observationId, trace_id: observationId,
  goal: '固定观察测试', spans: [span('observation:1', 'observation.service', '观察记录', 0, 'model_call')],
  edges: [], components: {}, planner_calls: [], model_calls: [observationCall],
  summary: { task_status: 'completed', elapsed_ms: 1000, event_count: 1, checkpoint_count: 1, final_count: 1,
    question_count: 0, reported_tokens_only: 25, model_ms_sum: 900, captured_model_calls: 1 },
  detail: { notes: [], questions: [] }, limitations: [], truncated: false, coverage: { source: 'test_fixture' }, checked_at: stamp(20) };

export async function installFixtures(page: Page): Promise<void> {
  await page.route('**/api/**', async route => {
    const path = new URL(route.request().url()).pathname;
    let json: unknown;
    if (route.request().method() !== 'GET') throw new Error(`Unexpected write in read-only UI test: ${path}`);
    if (path === '/api/topology') json = topology;
    else if (path === '/api/status') json = { mode: 'local_full', read_only: true, langfuse_url: '' };
    else if (path === '/api/tasks') json = { tasks: [{ id: taskId, goal: taskPath.goal, status: 'completed',
      updated_at: stamp(12), planner_calls: 5, action_count: 0 }] };
    else if (path === '/api/observations') json = { observations: [{ id: observationId, title: '固定观察测试',
      preset_label: '观察', status: 'completed', event_count: 1, updated_at: stamp(12) }] };
    else if (path === `/api/tasks/${taskId}/path`) json = taskPath;
    else if (path.startsWith(`/api/tasks/${taskId}/calls/`)) json = callDetail(Number(path.split('/').at(-1)));
    else if (path === `/api/observations/${observationId}/path`) json = observationPath;
    else if (path === `/api/observations/${observationId}/calls/${captureId}`) json = observationCall;
    else if (path.startsWith('/api/components/')) json = nodes.find(node => node.id === decodeURIComponent(path.split('/').at(-1)!));
    if (json === undefined) throw new Error(`Uncovered synthetic API contract: ${path}`);
    await route.fulfill({ json });
  });
}
