from __future__ import annotations

import unittest

from floweroll_host.capabilities_v0 import product_native_capabilities
from floweroll_host.capability_registry import (
    CapabilityRegistry,
    CapabilitySourceTarget,
    RegisteredCapability,
)
from floweroll_host.function_tool_adapter import FunctionToolAdapter
from floweroll_host.planner_contracts import CapabilitySpec
from floweroll_host.task_capability_policy import (
    EffectiveTaskCapabilityPolicy,
    TASK_DENIED,
    directives_from_text,
)


class TaskCapabilityPolicyParserTests(unittest.TestCase):
    def calendar_specs(self):
        specs = {spec.name: spec for spec in product_native_capabilities()}
        return specs["calendar.query"], specs["calendar.create"]

    def test_contacts_query_is_read_only_device_semantics(self) -> None:
        specs = {spec.name: spec for spec in product_native_capabilities()}
        contacts = specs["contacts.query"]
        read_policy = EffectiveTaskCapabilityPolicy.from_texts(["只查询联系人，不要创建或者修改联系人"] )
        self.assertTrue(read_policy.allows(contacts))
        decision = read_policy.decide(contacts)
        self.assertEqual(decision.operation, "read")
        self.assertIn("device", decision.domains)

    def test_contacts_family_is_device_only_and_read_only_goal_denies_writes(self) -> None:
        specs = {spec.name: spec for spec in product_native_capabilities()}
        policy = EffectiveTaskCapabilityPolicy.from_texts(["只查看联系人，不要创建或者修改联系人"])
        expected = {
            "contacts.query": ("read", True),
            "contacts.create": ("create", False),
            "contacts.update": ("modify", False),
        }
        for name, (operation, allowed) in expected.items():
            with self.subTest(name=name):
                decision = policy.decide(specs[name])
                self.assertEqual(decision.operation, operation)
                self.assertEqual(decision.domains, ("device",))
                self.assertEqual(decision.allowed, allowed)

    def generic_registry(self):
        registry = CapabilityRegistry()
        read_spec = CapabilitySpec(
            "generic.records.read",
            "Read project records without side effects.",
            {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
        )
        write_spec = CapabilitySpec(
            "generic.records.write",
            "Write project records.",
            {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
        )
        registry.register(
            RegisteredCapability(
                spec=read_spec,
                adapter=FunctionToolAdapter(
                    capability_id=read_spec.name,
                    source_kind="host_local",
                    read_only=True,
                ),
                source=CapabilitySourceTarget(
                    kind="host_local",
                    metadata={"read_only": True, "operation": "read", "domain": "work"},
                ),
            )
        )
        registry.register(
            RegisteredCapability(
                spec=write_spec,
                adapter=FunctionToolAdapter(
                    capability_id=write_spec.name,
                    source_kind="host_local",
                    read_only=False,
                    replay_safe=True,
                ),
                source=CapabilitySourceTarget(
                    kind="host_local",
                    metadata={"read_only": False, "operation": "write", "domain": "work"},
                ),
            )
        )
        return registry, read_spec, write_spec

    def test_unpunctuated_contrast_markers_split_operation_scoped_directives(self) -> None:
        connectors = ("但", "但是", "不过", "然而", "可是")
        for connector in connectors:
            with self.subTest(connector=connector, order="allow_then_deny"):
                directives = directives_from_text(
                    f"可以查询日程{connector}不要创建日程"
                )
                self.assertEqual(
                    [(item.mode, item.operations, item.domains) for item in directives],
                    [
                        ("ALLOW", frozenset({"read"}), frozenset({"device"})),
                        ("DENY", frozenset({"create"}), frozenset({"device"})),
                    ],
                )
            with self.subTest(connector=connector, order="deny_then_allow"):
                directives = directives_from_text(
                    f"不要创建日程{connector}可以查询日程"
                )
                self.assertEqual(
                    [(item.mode, item.operations, item.domains) for item in directives],
                    [
                        ("DENY", frozenset({"create"}), frozenset({"device"})),
                        ("ALLOW", frozenset({"read"}), frozenset({"device"})),
                    ],
                )

    def test_punctuation_controls_preserve_same_allow_and_deny_semantics(self) -> None:
        for text in (
            "可以查询日程，但是不要创建日程",
            "不要创建日程，但是可以查询日程",
            "可以查询日程；然而不要创建日程",
            "不要创建日程，不过可以查询日程",
        ):
            with self.subTest(text=text):
                query_spec, create_spec = self.calendar_specs()
                policy = EffectiveTaskCapabilityPolicy.from_texts([text])
                self.assertTrue(policy.allows(query_spec))
                decision = policy.decide(create_spec)
                self.assertFalse(decision.allowed)
                self.assertEqual(decision.reason_code, TASK_DENIED)

    def test_calendar_mixed_allow_deny_both_orders_deny_create_and_allow_query(self) -> None:
        query_spec, create_spec = self.calendar_specs()
        for text in (
            "可以查询日程但不要创建日程",
            "不要创建日程但可以查询日程",
            "可以查询日程但是不要创建日程",
            "不要创建日程不过可以查询日程",
            "可以查询日程然而不要创建日程",
        ):
            with self.subTest(text=text):
                policy = EffectiveTaskCapabilityPolicy.from_texts([text])
                self.assertTrue(policy.allows(query_spec))
                decision = policy.decide(create_spec)
                self.assertFalse(decision.allowed)
                self.assertEqual(decision.reason_code, TASK_DENIED)
                self.assertEqual(decision.operation, "create")
                self.assertIn("device", decision.domains)

    def test_generic_read_write_pair_keeps_allow_and_deny_operation_scoped(self) -> None:
        registry, read_spec, write_spec = self.generic_registry()
        for text in (
            "可以读取项目记录但不要写入项目记录",
            "不要写入项目记录但可以读取项目记录",
            "可以读取项目记录，但是不要写入项目记录",
            "不要写入项目记录，不过可以读取项目记录",
        ):
            with self.subTest(text=text):
                policy = EffectiveTaskCapabilityPolicy.from_texts([text])
                self.assertTrue(policy.allows(read_spec, registry))
                decision = policy.decide(write_spec, registry)
                self.assertFalse(decision.allowed)
                self.assertEqual(decision.reason_code, TASK_DENIED)
                self.assertEqual(decision.operation, "write")
                self.assertEqual(decision.domains, ("work",))

    def test_negated_permission_marker_is_deny_not_allow(self) -> None:
        query_spec, create_spec = self.calendar_specs()
        for text in (
            "不允许创建日程但可以查询日程",
            "不可以创建日程但是可以查询日程",
            "不要放开创建日程但可以查询日程",
        ):
            with self.subTest(text=text):
                policy = EffectiveTaskCapabilityPolicy.from_texts([text])
                self.assertTrue(policy.allows(query_spec))
                self.assertFalse(policy.allows(create_spec))

    def test_explicit_revocation_idiom_can_allow_same_operation(self) -> None:
        _, create_spec = self.calendar_specs()
        for text in (
            "不再禁止创建日程",
            "取消限制，可以创建日程",
            "恢复允许创建日程",
        ):
            with self.subTest(text=text):
                self.assertTrue(EffectiveTaskCapabilityPolicy.from_texts([text]).allows(create_spec))

    def test_later_allow_for_same_operation_still_revokes_earlier_deny(self) -> None:
        _, create_spec = self.calendar_specs()
        policy = EffectiveTaskCapabilityPolicy.from_texts(
            ["不要创建日程", "现在可以创建日程"]
        )
        self.assertTrue(policy.allows(create_spec))


if __name__ == "__main__":
    unittest.main()
