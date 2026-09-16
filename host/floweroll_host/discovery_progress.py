"""Bounded discovery bookkeeping. Runtime SQLite owns persistence/transactions.

This is a planning aid, not Task truth or a source of capability authorization.
A catalog/policy change invalidates negative knowledge; verified business progress
or a new explicit user turn replenishes the consecutive-search allowance.
"""
from __future__ import annotations

import hashlib
import json
from copy import deepcopy

MAX_SEARCHES_WITHOUT_PROGRESS = 6
MAX_DUPLICATE_PAGES = 2


def catalog_fingerprint(specs):
    body = [(s.name, s.description, s.arguments_schema) for s in sorted(specs, key=lambda s: s.name)
            if s.name != 'capability.search']
    return hashlib.sha256(json.dumps(body, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def progress_epoch(observations, user_turn_sequence=0):
    identities = []
    for row in observations:
        cap = row.get('capability')
        if cap == 'work.execute':
            for unit in row.get('data', {}).get('units', []):
                if unit.get('state') == 'completed' and unit.get('capability') != 'capability.search':
                    identities.append(unit.get('receipt_id') or unit.get('id'))
        elif cap not in {'capability.search', 'deliverables.status', 'deliverables.plan', 'deliverables.verify'}:
            identities.append(row.get('observation_id') or row.get('action_id'))
    return hashlib.sha256(json.dumps([identities, user_turn_sequence], sort_keys=True).encode()).hexdigest()


def state_view(saved, epoch):
    state = deepcopy(saved or {})
    if state.get('epoch') != epoch:
        state.update(epoch=epoch, used=0, duplicate_pages=0)
    state['limit'] = MAX_SEARCHES_WITHOUT_PROGRESS
    state['search_allowed'] = (state.get('used', 0) < MAX_SEARCHES_WITHOUT_PROGRESS
                               and state.get('duplicate_pages', 0) < MAX_DUPLICATE_PAGES)
    return state


def record_result(saved, epoch, catalog_key, result):
    state = state_view(saved if (saved or {}).get('catalog_key') == catalog_key else {}, epoch)
    state['catalog_key'] = catalog_key
    result = deepcopy(result)
    # Catalog identity includes schemas and the effective allowed/ready set.
    # Never reuse a negative finding after permissions/providers have changed.
    known = set(state.get('seen_ids', []))
    proposed = result.get('selected_capability_ids', [])
    novel = [name for name in proposed if name not in known]
    if not state['search_allowed']:
        result.update(matches=[], selected_capability_ids=[], new_capability_ids=[],
                      has_more=False, next_offset=None, search_allowed=False,
                      reason_code='discovery_progress_required',
                      notice='能力发现已收敛。先执行已找到的可用能力，或说明当前缺口；不要继续换关键词空转。其他独立事项仍可推进。')
        return state, result
    state['used'] = state.get('used', 0) + 1
    state['duplicate_pages'] = 0 if novel else state.get('duplicate_pages', 0) + 1
    state['seen_ids'] = sorted(known | set(proposed))
    # Keep small durable page descriptors, not entire repeated tool descriptions.
    page = {'query': result.get('query', ''), 'domain': result.get('domain', 'all'),
            'offset': result.get('offset', 0), 'ids': proposed,
            'exhausted': not result.get('has_more', False)}
    state['pages'] = [*(state.get('pages') or []), page][-24:]
    state = state_view(state, epoch)
    result.update(new_capability_ids=novel, repeated_page=not bool(novel),
                  search_allowed=state['search_allowed'],
                  searches_remaining=max(0, MAX_SEARCHES_WITHOUT_PROGRESS-state['used']))
    if not novel:
        result['notice'] = ('这些候选已发现过；换领域得到相同结果不代表新能力。优先执行已有工具，'
                            '缺失能力如实说明，并继续其他独立事项。')
    if not state['search_allowed']:
        result.update(has_more=False, next_offset=None)
        result['notice'] += ' 本轮发现预算已用尽，必须先取得业务进展；不能靠批处理绕过。'
    return state, result
