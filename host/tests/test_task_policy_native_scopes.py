import unittest

from floweroll_host.capabilities_v0 import product_native_capabilities
from floweroll_host.task_capability_policy import EffectiveTaskCapabilityPolicy


class NativeTaskPolicyScopeTests(unittest.TestCase):
    def setUp(self):
        self.specs = {spec.name: spec for spec in product_native_capabilities()}

    def test_deny_calendar_alarm_does_not_deny_reminder(self):
        policy = EffectiveTaskCapabilityPolicy.from_texts([
            '创建一个提醒事项，标题叫“验收提醒”。不要创建日历、闹钟或额外通知。'])
        for name, expected in {'reminder.create': True, 'reminder.query': True,
                               'reminder.remove': True, 'calendar.create': False,
                               'alarm.create': False, 'notify.user': False}.items():
            with self.subTest(name=name):
                self.assertEqual(policy.allows(self.specs[name]), expected)

    def test_later_allow_of_one_family_does_not_revoke_another_family_deny(self):
        policy = EffectiveTaskCapabilityPolicy.from_texts(['不要创建日历', '可以创建提醒事项'])
        self.assertFalse(policy.allows(self.specs['calendar.create']))
        self.assertTrue(policy.allows(self.specs['reminder.create']))

    def test_explicit_one_title_exception_is_advertised_but_enforced_at_dispatch(self):
        policy = EffectiveTaskCapabilityPolicy.from_texts([
            '创建一个提醒事项，标题叫“验收提醒”，时间明天9点。'
            '不要创建除这条测试提醒以外的其他提醒事项。'])
        spec = self.specs['reminder.create']
        self.assertTrue(policy.allows(spec))
        self.assertTrue(policy.decide(spec, arguments={'title': '验收提醒'}).allowed)
        self.assertFalse(policy.decide(spec, arguments={'title': '另一条提醒'}).allowed)
        self.assertFalse(policy.decide(spec, arguments={}).allowed)
        self.assertFalse(policy.decide(spec, arguments={'title': '验收提醒'},
                                      prior_created_titles=['验收提醒']).allowed)

    def test_ambiguous_exception_does_not_widen_authority(self):
        policy = EffectiveTaskCapabilityPolicy.from_texts([
            '创建一个提醒事项，标题叫“甲”。创建一个提醒事项，标题叫“乙”。'
            '不要创建除这条提醒以外的其他提醒事项。'])
        self.assertFalse(policy.allows(self.specs['reminder.create']))

    def test_quoted_exception_without_positive_target_is_denied(self):
        policy = EffectiveTaskCapabilityPolicy.from_texts(['不要创建除“未知目标”以外的其他提醒事项。'])
        self.assertFalse(policy.allows(self.specs['reminder.create']))

    def test_notify_without_create_or_send_verb_is_still_denied(self):
        policy = EffectiveTaskCapabilityPolicy.from_texts(['不要通知我'])
        self.assertFalse(policy.allows(self.specs['notify.user']))
        self.assertTrue(policy.allows(self.specs['reminder.create']))

    def test_read_only_contact_scope_does_not_restrict_calendar_create(self):
        policy = EffectiveTaskCapabilityPolicy.from_texts(['只查看联系人'])
        self.assertTrue(policy.allows(self.specs['contacts.query']))
        self.assertFalse(policy.allows(self.specs['contacts.create']))
        self.assertTrue(policy.allows(self.specs['calendar.create']))

    def test_global_prohibition_remains_global(self):
        policy = EffectiveTaskCapabilityPolicy.from_texts(['不要创建任何东西'])
        for name in ('reminder.create', 'calendar.create', 'contacts.create', 'alarm.create'):
            self.assertFalse(policy.allows(self.specs[name]))
