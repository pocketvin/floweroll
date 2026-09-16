"""Keep large retrieval bodies in durable storage, not every later model prompt."""
from __future__ import annotations
import copy,json,re
from typing import Any,Dict,List
from urllib.parse import urlsplit

_RETRIEVAL={'web.search','web.fetch','docs.query','docs.library.resolve'}

def project_observations(observations: List[Dict[str,Any]], per_retrieval_chars: int=5000) -> List[Dict[str,Any]]:
    projected=[]
    for original in observations:
        row=copy.deepcopy(original)
        if row.get('capability') == 'capability.search':
            data = row.get('data', {})
            row['data'] = {k: data[k] for k in (
                'query', 'domain', 'selected_capability_ids', 'new_capability_ids',
                'total_candidates', 'offset', 'next_offset', 'has_more', 'notice',
                'repeated_page', 'search_allowed', 'searches_remaining', 'reason_code') if k in data}
            projected.append(row)
            continue
        if row.get('capability') not in _RETRIEVAL:
            projected.append(row);continue
        data=row.get('data',{})
        encoded=json.dumps(data,ensure_ascii=False,separators=(',',':'))
        if len(encoded)<=per_retrieval_chars:
            projected.append(row);continue
        urls=[]
        for candidate in re.findall(r'https://[^\s<>"\\\)]+',encoded):
            url=candidate.rstrip('.,;')
            parsed=urlsplit(url)
            if parsed.hostname and not parsed.username and url not in urls and len(url)<600:urls.append(url)
        texts=[]
        def collect(value):
            if isinstance(value,dict):
                for key,item in value.items():
                    if key in {'text','body','snippet','description','title','content','structured_content'}:collect(item)
            elif isinstance(value,list):
                for item in value[:30]:collect(item)
            elif isinstance(value,str):texts.append(value)
        collect(data)
        # Preserve a bounded excerpt from each provider text block. Keep real
        # URLs separately so clipping cannot turn valid sources into invented links.
        allowance=max(250,per_retrieval_chars//max(1,len(texts)))
        excerpts=[text[:allowance] for text in texts[:20]]
        row['data']={
            'source_kind':data.get('source_kind'),
            'server_id':data.get('server_id'),
            'tool_name':data.get('tool_name'),
            'retrieved_urls':urls[:10],
            'text_excerpts':excerpts,
            'truncated':True,
            'original_char_count':len(encoded),
            'notice':'检索原文已保存在本任务Observation。此处只是片段，不能当完整原文。需要细节时用已检索URL读取或缩小搜索范围。',
        }
        projected.append(row)
    return projected
