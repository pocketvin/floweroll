"""Official hosted public search, optional and fail-closed on discovery errors."""
from __future__ import annotations

import os
from copy import deepcopy
from .capability_registry import CapabilityRegistry, CapabilitySourceTarget, RegisteredCapability
from .mcp_driver import MCPDriver, MCPServerConfig
from .mcp_adapter import MCPReadToolAdapter
from .planner_contracts import CapabilitySpec


def create_exa_search_driver() -> MCPDriver:
    return MCPDriver(MCPServerConfig(
        server_id='exa-search', endpoint='https://mcp.exa.ai/mcp?tools=web_search_exa',
        protocol_mode='legacy', timeout_seconds=20,
        headers={'User-Agent': 'Floweroll/0.1.1'},
        secret_header_env={'x-api-key':'EXA_API_KEY'} if os.environ.get('EXA_API_KEY') else {},
    ))


def register_exa_search(registry: CapabilityRegistry, driver: MCPDriver) -> bool:
    tool = next((t for t in driver.list_tools(force_refresh=True).tools if t.name == 'web_search_exa'), None)
    if tool is None:
        return False
    schema = deepcopy(tool.input_schema)
    schema.pop('$schema', None)
    if 'numResults' in schema.get('properties', {}):
        schema['properties']['numResults'].update({'minimum':1, 'maximum':6})
    spec = CapabilitySpec(name='web.search',
        description='搜索公开网页，返回标题、链接与内容摘录。公司资料优先官网，技术学习优先官方文档。只发送必要的公司/岗位/技术关键词，不把私人简历、联系方式或聊天原文发到搜索服务。搜索摘要不能证明实时房价、库存或订单。',
        arguments_schema=schema, post_verify_mode='REPLAN_REQUIRED')
    adapter = MCPReadToolAdapter(capability_id=spec.name, server_id='exa-search', tool_name=tool.name)
    registry.register(RegisteredCapability(spec=spec, adapter=adapter,
        source=CapabilitySourceTarget(kind='mcp', server_id='exa-search', tool_name=tool.name),
        tags=('web','search','read')))
    return True
