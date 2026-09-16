import {test,expect} from '@playwright/test';
import {installFixtures, taskId, requestEndMarker} from './fixtures';

test.beforeEach(async ({page}) => { await installFixtures(page); });
test('system map, navigation, task payloads and observation are usable',async({page}, _testInfo)=>{
 const errors:string[]=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('/');await expect(page.getByRole('heading',{name:'小卷的系统地图'})).toBeVisible();
 await expect(page.locator('.topology-dropdown')).not.toHaveAttribute('open','');
 await page.getByRole('button',{name:'收起导航',exact:true}).click();
 await expect(page.locator('.sidebar')).toHaveCSS('width','65px');
 await page.getByRole('button',{name:'展开导航',exact:true}).click();
 await page.locator('.record-list .record').first().click();
 await expect(page.getByLabel('任务关键指标')).toContainText('已报告 Token');
 await expect(page.getByLabel('模型上下文速览')).toContainText('System Prompt');
 await page.locator('.context-card').filter({hasText:'System Prompt'}).click();
 await expect(page.getByLabel('请求检查器')).toContainText('System Prompt');
 await expect(page.locator('.request-tabs button').filter({hasText:'System Prompt'})).toHaveClass(/selected/);
 await expect(page.getByLabel('详情检查器')).toHaveCount(0);
 await expect(page.getByLabel('执行记录')).toBeVisible();
 await page.locator('.topology-dropdown summary').click();
 await expect(page.getByLabel('系统拓扑画布')).toBeVisible();
 await expect(page.locator('.graph-card').first()).toBeVisible();
 await page.locator('.topology-dropdown summary').click();
 await expect(page.getByLabel('系统拓扑画布')).toBeHidden();
 await expect(page.getByLabel('执行记录')).toBeVisible();
 await page.getByRole('button',{name:'专注拓扑',exact:true}).click();
 await expect(page.getByLabel('系统拓扑画布')).toBeVisible();
 await expect(page.locator('.sidebar')).toBeHidden();
 await page.getByRole('button',{name:'退出拓扑专注',exact:true}).click();
 await page.getByRole('button',{name:/^观察 \d/}).click();
 await page.locator('.record-list .record').first().click();
 await expect(page.getByLabel('模型上下文速览')).toContainText('观察问答');
 const topology = page.locator('.topology-dropdown');
 if (!(await topology.getAttribute('open') === '')) await topology.locator('summary').click();
 await page.getByRole('button',{name:'本次执行',exact:true}).click();
 await expect(page.locator('.graph-card').first()).toBeVisible();
 await page.screenshot({path:_testInfo.outputPath('observation-browser.png')});
 expect(errors).toEqual([]);
});
test('system filtering, graph expansion and source inspector',async({page}, _testInfo)=>{
 await page.goto('/');await page.locator('.topology-dropdown summary').click();await expect(page.locator('.graph-card').first()).toBeVisible();
 await page.getByRole('button',{name:'展开 Planner 决策',exact:true}).click();
 await page.getByLabel('搜索节点').fill('build_context');
 await expect(page.locator('.graph-card')).toHaveCount(1);
 await page.locator('.graph-card').click();
 await expect(page.getByLabel('详情检查器')).toContainText('planner_graph.py');
 await page.keyboard.press('Escape');
 await expect(page.getByLabel('详情检查器')).toHaveCount(0);
 await page.getByLabel('搜索节点').fill('');
 await page.screenshot({path:_testInfo.outputPath('system-browser.png')});
});

test('dragged node survives refresh and execution search actually filters',async({page}, _testInfo)=>{
 await page.goto('/');await page.locator('.topology-dropdown summary').click();await expect(page.locator('.graph-card').first()).toBeVisible();
 await page.getByLabel('搜索节点').fill('task.runtime');
 const node=page.locator('.react-flow__node');await expect(node).toHaveCount(1);
 await expect(page.locator('.graph-loading')).toHaveCount(0);
 // Fit animation moves the node after it mounts. Wait for the viewport transform to settle before a physical drag.
 await expect.poll(async()=>{
   const before=await node.getAttribute('style');
   await page.waitForTimeout(120);
   return before===(await node.getAttribute('style')) && await page.locator('.react-flow__viewport').evaluate(async el=>{
     const a=el.getAttribute('style');await new Promise(r=>setTimeout(r,120));return a===el.getAttribute('style');
   });
 }).toBe(true);
 const box=await node.boundingBox();expect(box).not.toBeNull();
 await page.mouse.move(box!.x+box!.width/2,box!.y+35);await page.mouse.down();
 await page.mouse.move(box!.x+box!.width/2+50,box!.y+80,{steps:10});await page.mouse.up();
 const saved=await page.evaluate(()=>localStorage.getItem('floweroll.layout:system:v1'));
 expect(saved).toContain('task.runtime');
 await page.getByRole('button',{name:'刷新数据',exact:true}).click();
 expect(await page.evaluate(()=>localStorage.getItem('floweroll.layout:system:v1'))).toEqual(saved);
 await page.getByLabel('搜索节点').fill('');await page.locator('.record-list .record').first().click();
 await page.getByRole('button',{name:'本次执行',exact:true}).click();
 await page.getByLabel('搜索节点').fill('certainly-no-matching-component');
 await expect(page.locator('.graph-card')).toHaveCount(0);
 await page.getByLabel('搜索节点').fill('Planner');await expect(page.locator('.graph-card').first()).toBeVisible();
});

test('captured observation Prompt and result are accessible without clicking a graph node',async({page}, _testInfo)=>{
 const sid='11111111-1111-4111-8111-111111111111';const a='22222222-2222-4222-8222-222222222222';const b='33333333-3333-4333-8333-333333333333';
 const makeCall=(id:string,operation:string)=>({capture_id:id,operation,started_at:'2026-09-16T03:00:00Z',ended_at:'2026-09-16T03:00:01Z',duration_ms:1000,model_ms:850,model:'fixture-only',state:'finished',outcome:'model_validated',captured:true,request_bytes:100,reported_tokens:25,prompt_tokens:20,completion_tokens:5});
 await page.route('**/api/observations',route=>route.fulfill({json:{observations:[{id:sid,title:'独立接口夹具',preset_label:'观察',status:'completed',event_count:1,updated_at:'2026-09-16T03:00:01Z'}]}}));
 await page.route(`**/api/observations/${sid}/path`,route=>route.fulfill({json:{schema_version:1,kind:'observation',id:sid,trace_id:sid,goal:'独立接口夹具',spans:[],edges:[],components:{},planner_calls:[],model_calls:[makeCall(a,'observation.summary'),makeCall(b,'observation.vision')],summary:{task_status:'completed',elapsed_ms:1000,event_count:1,checkpoint_count:1,final_count:0,question_count:0,reported_tokens_only:50,model_ms_sum:1700,captured_model_calls:2},limitations:[],truncated:false,coverage:{source:'test_fixture'},checked_at:'2026-09-16T03:00:02Z',detail:{notes:[],questions:[]}}}));
 await page.route(`**/api/observations/${sid}/calls/*`,route=>{const isA=route.request().url().endsWith(a);return route.fulfill({json:{...makeCall(isA?a:b,isA?'observation.summary':'observation.vision'),available:true,note:'仅测试数据',system_prompt:isA?'SUMMARY_CAPTURED_PROMPT':'VISION_CAPTURED_PROMPT',context:{test:isA?'summary':'vision'},wire_request:{model:'fixture-only'},model_response:{summary:isA?'SUMMARY_REAL_RESPONSE':'VISION_REAL_RESPONSE'},prompt_matches_current:true}})});
 await page.goto('/');await page.getByRole('button',{name:/^观察 \d/}).click();await page.locator('.record-list .record').first().click();
 await expect(page.getByLabel('模型上下文速览')).toContainText('VISION_CAPTURED_PROMPT');
 await page.getByLabel('选择观察模型调用').selectOption(a);
 await expect(page.getByLabel('模型上下文速览')).toContainText('SUMMARY_CAPTURED_PROMPT');
 await expect(page.getByLabel('模型上下文速览')).not.toContainText('VISION_CAPTURED_PROMPT');
 await page.locator('.context-card').filter({hasText:'System Prompt'}).click();
 await expect(page.getByLabel('请求检查器')).toContainText('SUMMARY_CAPTURED_PROMPT');
 await expect(page.locator('.request-tabs button').filter({hasText:'System Prompt'})).toHaveClass(/selected/);
 await expect(page.getByLabel('详情检查器')).toHaveCount(0);
 await page.locator('.context-card').filter({hasText:'模型结果'}).click();
 await expect(page.getByLabel('请求检查器')).toContainText('SUMMARY_REAL_RESPONSE');
 await expect(page.locator('.request-tabs button').filter({hasText:'模型结果'})).toHaveClass(/selected/);
 await expect(page.getByLabel('详情检查器')).toHaveCount(0);
});

test('canvas stays usable with collapsed navigation at a smaller desktop size',async({page}, _testInfo)=>{
 await page.setViewportSize({width:1100,height:720});await page.goto('/');
 await page.locator('.topology-dropdown summary').click();await expect(page.locator('.graph-card').first()).toBeVisible();
 await page.getByRole('button',{name:'收起导航',exact:true}).click();
 await expect(page.locator('.sidebar')).toHaveCSS('width','65px');
 const canvas=await page.getByLabel('系统拓扑画布').boundingBox();
 expect(canvas!.width).toBeGreaterThan(900);expect(canvas!.height).toBeGreaterThan(400);
 await page.screenshot({path:_testInfo.outputPath('compact-browser.png')});
});


test('topology stays collapsed by default and expands on demand',async({page}, _testInfo)=>{
 await page.setViewportSize({width:1440,height:960});await page.goto('/');
 await page.locator('.record-list .record').first().click();
 await expect(page.getByLabel('任务关键指标')).toBeVisible();
 await expect(page.getByLabel('模型上下文速览')).toBeVisible();
 await expect(page.getByLabel('执行记录')).toBeVisible();
 await expect(page.locator('.topology-dropdown')).not.toHaveAttribute('open','');
 await expect(page.getByLabel('系统拓扑画布')).toBeHidden();
 await page.locator('.topology-dropdown summary').click();
 await expect(page.locator('.topology-dropdown')).toHaveAttribute('open','');
 await expect(page.getByLabel('系统拓扑画布')).toBeVisible();
 await page.locator('.topology-dropdown summary').click();
 await expect(page.getByLabel('执行记录')).toBeVisible();
 await expect(page.getByLabel('系统拓扑画布')).toBeHidden();
});

test('selected task is detail-first and shows chronological records before topology',async({page}, _testInfo)=>{
 await page.goto('/');await page.locator('.record-list .record').first().click();
 await expect(page.getByLabel('任务关键指标')).toBeVisible();
 await expect(page.getByLabel('本次执行主线')).toBeVisible();
 await expect(page.getByLabel('执行记录')).toBeVisible();
 await expect(page.locator('.topology-dropdown')).not.toHaveAttribute('open','');
 const orders=page.locator('.primary-timeline .timeline-order');await expect(orders.first()).toContainText('#01');
 await page.locator('.topology-dropdown summary').click();
 await expect(page.getByRole('button',{name:'展开 Planner 内部',exact:true})).toBeVisible();
 await expect(page.locator('.graph-card')).not.toContainText(['build_context']);
 await page.getByRole('button',{name:'展开 Planner 内部',exact:true}).click();
 await expect(page.locator('.graph-card').filter({hasText:'build_context'}).first()).toBeVisible();
});

test('system topology exposes iOS Host and External regions without mixing them into runtime truth',async({page}, _testInfo)=>{
 await page.goto('/');await expect(page.getByRole('heading',{name:'小卷的系统地图'})).toBeVisible();
 await page.locator('.topology-dropdown summary').click();
 await expect(page.getByLabel('筛选系统区域')).toBeVisible();
 await expect(page.locator('.system-zone-hint')).toContainText('iOS 设备');
 await expect(page.locator('.system-zone-hint')).toContainText('Host');
 await expect(page.locator('.system-zone-hint')).toContainText('External');
 await page.getByLabel('筛选系统区域').selectOption('ios');
 await expect(page.locator('.graph-card').first()).toContainText('iOS 设备');
 await page.getByLabel('筛选系统区域').selectOption('external');
 await expect(page.locator('.graph-card').first()).toContainText('外部服务');
 await page.screenshot({path:_testInfo.outputPath('system-zones.png')});
});

test('planner rows switch the persistent request inspector without opening an overlay',async({page}, _testInfo)=>{
 await page.goto(`/#task/${taskId}`);
 await expect(page.getByLabel('请求检查器')).toBeVisible();
 const p1=page.locator('.timeline-select').filter({hasText:'Planner #1'}).first();
 const p2=page.locator('.timeline-select').filter({hasText:'Planner #2'}).first();
 await expect(p1).toBeVisible();await expect(p2).toBeVisible();
 await p1.click();
 await expect(page.getByLabel('选择 Planner 调用')).toHaveValue('1');
 await expect(page.getByLabel('详情检查器')).toHaveCount(0);
 const modelTab=page.locator('.request-tabs button').filter({hasText:'模型结果'});
 await modelTab.click();await expect(modelTab).toHaveClass(/selected/);
 await p2.click();
 await expect(page.getByLabel('选择 Planner 调用')).toHaveValue('2');
 await expect(modelTab).toHaveClass(/selected/);
 await expect(page.getByLabel('详情检查器')).toHaveCount(0);
 const decisionCard=page.locator('.context-card').filter({hasText:'决策与采纳'});
 await decisionCard.click();
 await expect(page.locator('.request-tabs button').filter({hasText:'决策与采纳'})).toHaveClass(/selected/);
 await expect(page.getByLabel('详情检查器')).toHaveCount(0);
});

test('full request viewer exposes per-message copy controls and expands without truncating the frontend',async({page}, _testInfo)=>{
 const tid=taskId;
 await page.goto(`/#task/${tid}`);
 await page.getByLabel('选择 Planner 调用').selectOption('5');
 await expect(page.getByLabel('请求检查器')).toContainText('完整采集');
 await page.locator('.request-tabs button').filter({hasText:'用户消息'}).click();
 await expect(page.getByLabel('请求检查器')).toContainText('首条用户消息');
 await expect(page.getByLabel('请求检查器')).toContainText('继续安排');
 await expect(page.locator('.copy-message button').first()).toHaveText(/复制/);
 await page.locator('.request-tabs button').filter({hasText:'原始请求'}).click();
 await expect(page.getByLabel('请求检查器')).toContainText('完整原始请求 JSON');
 await expect(page.getByLabel('请求检查器')).toContainText(requestEndMarker);
 await expect(page.locator('.wire-message-card')).toHaveCount(2);
 await expect(page.locator('.wire-message-card button').first()).toHaveText(/复制这条消息/);
 await page.getByRole('button',{name:'放大查看',exact:true}).click();
 await expect(page.getByLabel('请求检查器')).toHaveClass(/expanded/);
 await expect(page.getByRole('button',{name:'复制当前',exact:true})).toBeVisible();
 await page.getByRole('button',{name:'恢复布局',exact:true}).click();
 await expect(page.getByLabel('请求检查器')).not.toHaveClass(/expanded/);
});


test('focus mode has keyboard and collapse exits without losing selection', async ({page}) => {
  await page.goto(`/#task/${taskId}`);
  await expect(page.getByLabel('请求检查器')).toBeVisible();
  await page.getByRole('button', {name:'专注拓扑',exact:true}).click();
  await expect(page.getByRole('button', {name:'退出拓扑专注',exact:true})).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByLabel('导航栏')).toBeVisible();
  await expect(page.getByLabel('请求检查器')).toBeVisible();
  await expect(page).toHaveURL(new RegExp(taskId));
  await page.getByRole('button', {name:'专注拓扑',exact:true}).click();
  await page.locator('.topology-dropdown summary').click();
  await expect(page.getByLabel('导航栏')).toBeVisible();
  await expect(page.getByLabel('系统拓扑画布')).toBeHidden();
  await expect(page.getByLabel('请求检查器')).toBeVisible();
});


test('reselecting the current Planner or observation does not erase captured detail', async ({page}) => {
  await page.goto(`/#task/${taskId}`);
  const inspector = page.getByLabel('请求检查器');
  await expect(inspector).toContainText('完整采集');
  await page.locator('.timeline-select').filter({hasText:'Planner #5'}).first().click();
  await expect(inspector).toContainText('完整采集');
  await page.getByLabel('选择 Planner 调用').selectOption('5');
  await expect(inspector).toContainText('完整采集');
  await page.getByRole('button',{name:/^观察 \d/}).click();
  await page.locator('.record-list .record').first().click();
  await expect(inspector).toContainText('FIXTURE_OBSERVATION_PROMPT');
  const calls = page.getByLabel('选择观察模型调用');
  await calls.selectOption(await calls.inputValue());
  await expect(inspector).toContainText('FIXTURE_OBSERVATION_PROMPT');
});
