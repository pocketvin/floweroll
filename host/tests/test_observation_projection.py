import copy
import json
import unittest

from floweroll_host.observation_projection import project_observations
from floweroll_host.planner_contracts import CapabilitySpec, DecisionContext
from floweroll_host.planner_compaction import compact_context, project_evidence


class ObservationProjectionTests(unittest.TestCase):
    def test_large_retrieval_is_projected_but_provenance_and_urls_survive(self):
        original = [{'action_id': 'a', 'observation_id': 'o', 'capability': 'web.search', 'data': {
            'source_kind': 'mcp', 'content': [{'type': 'text', 'text':
                'https://example.com/source\n' + ('detail ' * 10000)}]}}]
        untouched = copy.deepcopy(original)
        result = project_observations(original)
        self.assertEqual(original, untouched)
        self.assertEqual(result[0]['observation_id'], 'o')
        self.assertIn('https://example.com/source', result[0]['data']['retrieved_urls'])
        self.assertTrue(result[0]['data']['truncated'])
        self.assertLess(len(json.dumps(result)), 6500)

    def test_device_receipts_are_never_discarded_or_rewritten(self):
        original = [{'capability': 'calendar.query', 'data': {'event_id': 'real-event', 'verified': True}}]
        self.assertEqual(project_observations(original), original)

    def test_small_search_keeps_full_schema(self):
        original = [{'capability': 'web.search', 'data': {'content': [{'type': 'text', 'text': 'small'}]}}]
        self.assertEqual(project_observations(original), original)

    def test_repeated_projection_is_idempotent_and_keeps_body(self):
        original = [{'observation_id': 'evidence', 'capability': 'web.search', 'data': {
            'source_kind': 'mcp', 'content': [{'type': 'text', 'text':
                'Title: 铁路信息\nURL: https://example.com/train\nHighlights:\n'
                '杭州东至上海虹桥 G7530 历时1小时，二等座87元。\n' * 600}]}}]
        once = project_observations(original)
        self.assertEqual(project_observations(once), once)
        self.assertIn('二等座87元', json.dumps(project_evidence(once), ensure_ascii=False))
        self.assertEqual(original[0]['data']['source_kind'], 'mcp')

    def test_legacy_projected_evidence_is_not_projected_to_empty(self):
        original = [{'capability': 'web.search', 'data': {
            'source_kind': 'mcp', 'retrieved_urls': ['https://example.com/train'],
            'text_excerpts': ['班次G7530约1小时，二等座87元。' * 450],
            'truncated': True, 'original_char_count': 30000}}]
        normal = project_observations(original)
        recovery = project_evidence(normal, recovery=True)
        self.assertIn('二等座87元', json.dumps(recovery, ensure_ascii=False))
        self.assertIn('https://example.com/train', json.dumps(recovery))

    def test_each_exa_source_gets_an_excerpt_not_just_the_first_page(self):
        blocks = []
        for index in range(6):
            blocks.append(f'Title: 来源{index}\nURL: https://example.com/source-{index}\n'
                          f'Highlights:\n来源{index}车程{index + 1}小时费用{index + 80}元。\n' + '背景文字\n' * 1000)
        original = [{'capability': 'web.search', 'data': {'content': [{'type': 'text', 'text':
            '\n\n---\n\n'.join(blocks)}]}}]
        projected = project_observations(original)
        text = '\n'.join(projected[0]['data']['text_excerpts'])
        for index in range(6):
            self.assertIn(f'来源{index}车程{index + 1}小时费用{index + 80}元', text)
        self.assertLessEqual(sum(map(len, projected[0]['data']['text_excerpts'])), 5000)

    def test_structured_search_results_are_walked(self):
        original = [{'capability': 'web.search', 'data': {'structured_content': {'results': [
            {'url': 'https://example.com/a', 'text': '票价87元。' + '资料' * 6000},
            {'url': 'https://example.com/b', 'text': '历时1小时。' + '资料' * 6000},
        ]}}}]
        text = json.dumps(project_observations(original), ensure_ascii=False)
        self.assertIn('票价87元', text)
        self.assertIn('历时1小时', text)

    def test_recovery_reduces_budget_without_losing_excerpt_identity(self):
        original = [{'capability': 'web.fetch', 'data': {'url': 'https://example.com/a',
            'text': '可引用事实：费用87元，车程1小时。\n' + '资料' * 10000}}]
        normal = project_observations(original)
        recovery = project_observations(normal, per_retrieval_chars=1800)
        self.assertIn('费用87元', json.dumps(recovery, ensure_ascii=False))
        self.assertEqual(project_observations(recovery, per_retrieval_chars=1800), recovery)
        self.assertLessEqual(sum(map(len, recovery[0]['data']['text_excerpts'])), 1800)


class PlannerStructuredReceiptProjectionTests(unittest.TestCase):
    def test_capability_search_drops_verbose_catalog_after_selector_but_keeps_progress(self):
        row = [{
            'capability': 'capability.search',
            'data': {
                'query': '火车时刻表', 'domain': 'travel', 'offset': 6, 'next_offset': 12,
                'has_more': True, 'searches_remaining': 3,
                'selected_capability_ids': ['travel.hotel.search'],
                'new_capability_ids': ['travel.hotel.search'],
                'matches': [{'capability_id': f'cap-{i}', 'description': '说明' * 1000} for i in range(8)],
                'domains': [{'domain': 'travel', 'description': '旅行' * 1000}],
            },
        }]
        compact = project_evidence(row)
        data = compact[0]['data']
        self.assertEqual(data['query'], '火车时刻表')
        self.assertEqual(data['offset'], 6)
        self.assertEqual(data['next_offset'], 12)
        self.assertEqual(data['selected_capability_ids'], ['travel.hotel.search'])
        self.assertNotIn('matches', data)
        self.assertNotIn('domains', data)
        self.assertLess(len(json.dumps(compact, ensure_ascii=False)), 1200)

    def test_hotel_projection_keeps_region_price_range_examples_and_uncertainty(self):
        items = []
        for index, price in enumerate((315, 861, 66, 228, 113, 147, 216, 232, 147, 254)):
            items.append({
                'name': f'酒店{index}', 'provider_item_id': f'id-{index}',
                'price_amount': float(price), 'price_raw': f'¥{price}', 'price_exact': True,
                'currency': 'CNY', 'star': '经济型', 'nearby': '近地铁站',
                'provider_poi_text_match': index == 1,
                'address': '很长地址' * 100, 'main_image_url': 'https://example.com/' + ('x' * 400),
                'detail_url': 'https://example.com/detail/' + ('y' * 400),
            })
        row = [{'capability': 'travel.hotel.search', 'data': {
            'source_kind': 'managed_cli', 'capability': 'travel.hotel.search',
            'provider': 'flyai_fliggy', 'currency': 'CNY', 'item_count': 10,
            'exact_price_count': 10, 'price_data_complete': True,
            'poi_filter_requested': True, 'poi_filter_verified': False,
            'proximity_verification_required': True,
            'query': {'destination': '上海', 'poi_name': '上海虹桥站', 'check_in_date': '2026-09-22'},
            'items': items,
        }}]
        compact = project_evidence(row)
        data = compact[0]['data']
        self.assertEqual(data['query']['poi_name'], '上海虹桥站')
        self.assertEqual(data['exact_price_range']['min'], 66.0)
        self.assertEqual(data['exact_price_range']['max'], 861.0)
        self.assertFalse(data['poi_filter_verified'])
        self.assertTrue(data['proximity_verification_required'])
        self.assertTrue(any(item.get('provider_poi_text_match') for item in data['representative_items']))
        self.assertLessEqual(len(data['representative_items']), 4)
        self.assertNotIn('items', data)
        self.assertLess(len(json.dumps(compact, ensure_ascii=False)), 3000)


class PlannerContextBudgetTests(unittest.TestCase):
    def test_compaction_aggregates_discovery_bounds_memory_and_keeps_weather_facts(self):
        discovery = []
        for index in range(6):
            discovery.append({
                'observation_id': f's-{index}', 'capability': 'capability.search', 'data': {
                    'query': f'火车查询{index}', 'domain': 'travel', 'offset': index * 6,
                    'next_offset': (index + 1) * 6, 'has_more': True,
                    'new_capability_ids': [f'cap-{index}'],
                    'selected_capability_ids': [f'cap-{index}'],
                    'matches': [{'description': '大段说明' * 1000}],
                },
            })
        weather = {'observation_id': 'weather', 'capability': 'weather.query', 'data': {
            'source_kind': 'mcp', 'server_id': 'amap', 'tool_name': 'maps_weather',
            'structured_content': {'city': '杭州市', 'forecasts': [
                {'date': '2026-09-22', 'dayweather': '多云', 'nightweather': '多云',
                 'daytemp': '30', 'nighttemp': '23', 'daywind': '东', 'nightwind': '东',
                 'daypower': '1-3', 'nightpower': '1-3', 'daytemp_float': '30.0'},
            ]},
            'content': [{'type': 'text', 'text': json.dumps({'city': '杭州市', 'forecasts': [{'date': '2026-09-22', 'dayweather': '多云', 'nightweather': '多云', 'daytemp': '30', 'nighttemp': '23', 'daywind': '东', 'nightwind': '东', 'daypower': '1-3', 'nightpower': '1-3', 'daytemp_float': '30.0'}]}, ensure_ascii=False)}],
        }}
        spec = CapabilitySpec('web.search', '搜索网页', {
            'type': 'object', 'properties': {'query': {'type': 'string'}},
            'required': ['query'], 'additionalProperties': False,
        }, 'REPLAN_REQUIRED')
        context = DecisionContext(
            task_id='task', raw_goal='查询并规划', task_status='ACTIVE', phase='planning',
            current_time='2026-09-21T05:00:00+08:00', timezone='Asia/Shanghai',
            policy_view={}, capabilities=[spec], verified_observations=discovery + [weather],
            runtime_context={'relevant_memories': [
                {'memory': ('旧任务记忆' + str(i)) * 100, 'memory_id': str(i),
                 'score': 1 - i / 10, 'categories': ['travel']} for i in range(5)
            ]},
        )
        compact, _ = compact_context(context)
        self.assertFalse(any(row['capability'] == 'capability.search' for row in compact.verified_observations))
        evidence = compact.runtime_context['capability_discovery_evidence']
        self.assertEqual(evidence['attempt_count'], 6)
        self.assertEqual(len(evidence['recent_searches']), 4)
        self.assertEqual(len(compact.runtime_context['relevant_memories']), 3)
        self.assertTrue(all(len(item['memory']) <= 260 for item in compact.runtime_context['relevant_memories']))
        weather_data = compact.verified_observations[0]['data']
        self.assertEqual(weather_data['structured_content']['city'], '杭州市')
        self.assertEqual(weather_data['structured_content']['forecasts'][0]['daytemp'], '30')
        self.assertNotIn('content', weather_data)

    def test_completed_work_batch_parent_is_omitted_only_when_child_receipts_cover_it(self):
        spec = CapabilitySpec('web.search', '搜索网页', {
            'type': 'object', 'properties': {}, 'required': [], 'additionalProperties': False,
        }, 'REPLAN_REQUIRED')
        child = {
            'observation_id': 'child', 'action_id': 'child', 'parent_action_id': 'parent',
            'work_unit_id': 'unit-a', 'capability': 'weather.query',
            'data': {'structured_content': {'city': '上海市', 'forecasts': []}},
        }
        parent = {
            'observation_id': 'parent', 'capability': 'work.execute', 'data': {
                'units': [{'id': 'unit-a', 'state': 'completed', 'receipt_id': 'child'}],
                'completed': 1, 'total': 1, 'all_completed': True,
            },
        }
        context = DecisionContext(
            task_id='task', raw_goal='test', task_status='ACTIVE', phase='planning',
            current_time='2026-09-21T05:00:00+08:00', timezone='Asia/Shanghai',
            policy_view={}, capabilities=[spec], verified_observations=[parent, child],
        )
        compact, _ = compact_context(context)
        self.assertEqual([row['capability'] for row in compact.verified_observations], ['weather.query'])
        self.assertEqual(compact.runtime_context['completed_work_batch_count'], 1)

        uncovered = DecisionContext(
            task_id='task', raw_goal='test', task_status='ACTIVE', phase='planning',
            current_time='2026-09-21T05:00:00+08:00', timezone='Asia/Shanghai',
            policy_view={}, capabilities=[spec], verified_observations=[parent],
        )
        compact_uncovered, _ = compact_context(uncovered)
        self.assertEqual(compact_uncovered.verified_observations[0]['capability'], 'work.execute')
        self.assertEqual(compact_uncovered.verified_observations[0]['data']['units'][0]['id'], 'unit-a')
