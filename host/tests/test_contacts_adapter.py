from __future__ import annotations

import unittest

from floweroll_host.contacts_adapter import (
    ContactsCreateAdapter,
    ContactsQueryAdapter,
    ContactsUpdateAdapter,
    normalize_contacts_create_arguments,
    normalize_contacts_query_arguments,
    normalize_contacts_update_arguments,
)


class ContactsQueryAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.adapter = ContactsQueryAdapter()

    def action(self, payload):
        return {"payload": payload, "idempotency_key": "idem-contacts"}

    def exact_output(self):
        return {
            "query_mode": "exact_id",
            "authorization_scope": "authorized",
            "found": True,
            "requested_contact_id": "requested-1",
            "name_query": None,
            "contacts": [{
                "requested_contact_id": "requested-1",
                "contact_id": "canonical-1",
                "canonicalized": True,
                "requested_id_linked_into_result": True,
                "contact_type": "person",
                "display_name": "Ada Lovelace",
                "given_name": "Ada",
                "family_name": "Lovelace",
                "organization_name": None,
                "phone_numbers": [{"label": "mobile", "value": "+1 555 0100"}],
                "email_addresses": [{"label": "work", "value": "ada@example.com"}],
                "phone_values_truncated": False,
                "email_values_truncated": False,
                "revision": None,
                "update_eligible": False,
                "update_ineligible_reason": "linked_contact_unsupported",
                "representation": "unified_contact",
                "container_resolution": "linked_or_ambiguous",
            }],
            "truncated": False,
            "empty_reason": None,
            "verified": True,
        }

    def name_output(self):
        return {
            "query_mode": "name",
            "authorization_scope": "limited",
            "found": True,
            "requested_contact_id": None,
            "name_query": "Ada",
            "contacts": [{
                "contact_id": "canonical-1",
                "contact_type": "person",
                "display_name": "Ada Lovelace",
                "organization_name": "Analytical Engine",
                "phone_hints": ["••••0100"],
                "email_hints": ["a•••@example.com"],
                "representation": "unified_contact",
                "container_resolution": "deferred_v1",
            }],
            "truncated": False,
            "empty_reason": None,
            "verified": True,
        }

    def test_argument_contract_exact_or_bounded_name_only(self):
        self.assertEqual(
            normalize_contacts_query_arguments({"contact_id": " id-1 "}),
            {"mode": "exact_id", "contact_id": "id-1", "name_query": None, "max_results": 1},
        )
        self.assertEqual(
            normalize_contacts_query_arguments({"name_query": " Ada ", "max_results": 3}),
            {"mode": "name", "contact_id": None, "name_query": "Ada", "max_results": 3},
        )
        for payload in (
            {},
            {"contact_id": "id", "name_query": "Ada"},
            {"contact_id": "id", "max_results": 2},
            {"name_query": "A"},
            {"name_query": "Ada", "max_results": 0},
            {"name_query": "Ada", "max_results": 11},
            {"name_query": "Ada", "extra": True},
        ):
            with self.subTest(payload=payload):
                self.assertIsNone(normalize_contacts_query_arguments(payload))

    def test_exact_result_accepts_canonical_alias_only_with_proof(self):
        output = self.exact_output()
        verdict = self.adapter.verify_result(
            self.action({"contact_id": "requested-1"}), success=True, output=output, error=None
        )
        self.assertEqual(verdict.outcome, "SUCCESS")
        self.assertEqual(verdict.observation["contacts"][0]["contact_id"], "canonical-1")

        output["contacts"][0]["requested_id_linked_into_result"] = False
        rejected = self.adapter.verify_result(
            self.action({"contact_id": "requested-1"}), success=True, output=output, error=None
        )
        self.assertEqual(rejected.outcome, "TERMINAL_FAILURE")

    def test_name_result_rejects_raw_contact_method_fields(self):
        output = self.name_output()
        verdict = self.adapter.verify_result(
            self.action({"name_query": "Ada", "max_results": 5}), success=True, output=output, error=None
        )
        self.assertEqual(verdict.outcome, "SUCCESS")
        output["contacts"][0]["phone_numbers"] = [{"label": "mobile", "value": "+1 555 0100"}]
        rejected = self.adapter.verify_result(
            self.action({"name_query": "Ada", "max_results": 5}), success=True, output=output, error=None
        )
        self.assertEqual(rejected.outcome, "TERMINAL_FAILURE")

    def test_limited_empty_is_not_global_absence(self):
        output = self.name_output()
        output.update({"found": False, "contacts": [], "empty_reason": "not_accessible_or_not_found"})
        verdict = self.adapter.verify_result(
            self.action({"name_query": "Ada"}), success=True, output=output, error=None
        )
        self.assertEqual(verdict.outcome, "SUCCESS")
        self.assertIn("允许小卷访问", verdict.direct_completion_summary)

        output["empty_reason"] = "no_match"
        rejected = self.adapter.verify_result(
            self.action({"name_query": "Ada"}), success=True, output=output, error=None
        )
        self.assertEqual(rejected.outcome, "TERMINAL_FAILURE")

    def test_permission_and_store_change_failure_mapping(self):
        for code, expected in (
            ("CONTACTS_PERMISSION_NOT_DETERMINED", "MODEL_CORRECTABLE_FAILURE"),
            ("CONTACTS_PERMISSION_DENIED", "MODEL_CORRECTABLE_FAILURE"),
            ("CONTACTS_PERMISSION_RESTRICTED", "TERMINAL_FAILURE"),
            ("CONTACTS_PERMISSION_UNKNOWN", "TERMINAL_FAILURE"),
            ("CONTACTS_STORE_CHANGED_RETRY_SAFE", "TRANSIENT_FAILURE"),
        ):
            with self.subTest(code=code):
                verdict = self.adapter.verify_result(
                    self.action({"name_query": "Ada"}),
                    success=False,
                    output={"error_code": code},
                    error=None,
                )
                self.assertEqual(verdict.outcome, expected)

    def test_name_result_is_bounded_and_unique(self):
        output = self.name_output()
        output["contacts"] = output["contacts"] * 2
        duplicate = self.adapter.verify_result(
            self.action({"name_query": "Ada", "max_results": 5}), success=True, output=output, error=None
        )
        self.assertEqual(duplicate.outcome, "TERMINAL_FAILURE")

        output = self.name_output()
        output["contacts"] = [dict(output["contacts"][0], contact_id=f"id-{i}") for i in range(3)]
        too_many = self.adapter.verify_result(
            self.action({"name_query": "Ada", "max_results": 2}), success=True, output=output, error=None
        )
        self.assertEqual(too_many.outcome, "TERMINAL_FAILURE")


class ContactsMutationAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.create = ContactsCreateAdapter()
        self.update = ContactsUpdateAdapter()
        self.desired = {
            "given_name": "Ada",
            "family_name": "Lovelace",
            "organization_name": "Analytical Engine",
            "phone_numbers": [{"label": "mobile", "value": "+1 555 0100"}],
            "email_addresses": [{"label": "work", "value": "ada@example.com"}],
        }

    def action(self, payload):
        return {"payload": payload, "idempotency_key": "idem-contact-write"}

    def managed_common(self):
        return {
            "authorization_scope": "limited",
            "contact_id": "contact-1",
            "contact_type": "person",
            "display_name": "Ada Lovelace",
            **self.desired,
            "revision": "a" * 64,
            "update_eligible": True,
            "update_ineligible_reason": None,
            "applied": True,
            "verified": True,
        }

    def test_create_normalization_and_confirmation_are_bounded(self):
        normalized = normalize_contacts_create_arguments({
            "given_name": " Ada ",
            "family_name": " Lovelace ",
            "organization_name": " Analytical Engine ",
            "phone_numbers": [{"label": "mobile", "value": " +1 555 0100 "}],
            "email_addresses": [{"label": "work", "value": " ada@example.com "}],
        })
        self.assertEqual(normalized, self.desired)
        confirmation = self.create.predispatch_confirmation(self.action(self.desired))
        self.assertEqual(confirmation["reason"], "side_effect_approval")
        self.assertIn("确认创建", [item["label"] for item in confirmation["suggested_options"]])
        self.assertEqual(confirmation["execution_fields"], self.desired)

        self.assertIsNone(normalize_contacts_create_arguments({**self.desired, "extra": True}))
        self.assertIsNone(normalize_contacts_create_arguments({**self.desired, "phone_numbers": [{"label": "bad", "value": "1"}]}))
        self.assertIsNone(normalize_contacts_create_arguments({
            "given_name": "", "family_name": "", "organization_name": "",
            "phone_numbers": [], "email_addresses": [],
        }))

    def test_create_verifier_requires_native_identity_and_exact_readback(self):
        output = {
            **self.managed_common(),
            "operation": "create",
            "created_contact_id": "created-1",
            "canonicalized": True,
            "created_id_linked_into_result": True,
        }
        output["contact_id"] = "canonical-1"
        output["update_eligible"] = False
        output["revision"] = None
        output["update_ineligible_reason"] = "linked_contact_unsupported"
        verdict = self.create.verify_result(self.action(self.desired), success=True, output=output, error=None)
        self.assertEqual(verdict.outcome, "SUCCESS")
        self.assertNotIn("created_contact_id", verdict.observation)

        output["created_id_linked_into_result"] = False
        rejected = self.create.verify_result(self.action(self.desired), success=True, output=output, error=None)
        self.assertEqual(rejected.outcome, "TERMINAL_FAILURE")

    def test_update_requires_fresh_revision_exact_target_and_complete_state(self):
        payload = {"contact_id": "contact-1", "expected_revision": "b" * 64, **self.desired}
        normalized = normalize_contacts_update_arguments(payload)
        self.assertEqual(normalized["contact_id"], "contact-1")
        self.assertEqual(normalized["expected_revision"], "b" * 64)

        output = {**self.managed_common(), "operation": "update", "requested_contact_id": "contact-1"}
        verdict = self.update.verify_result(self.action(payload), success=True, output=output, error=None)
        self.assertEqual(verdict.outcome, "SUCCESS")
        self.assertEqual(verdict.observation["contact_id"], "contact-1")

        output["family_name"] = "Byron"
        rejected = self.update.verify_result(self.action(payload), success=True, output=output, error=None)
        self.assertEqual(rejected.outcome, "TERMINAL_FAILURE")

    def test_mutation_failure_mapping_never_turns_restricted_or_native_save_into_retry(self):
        for adapter, payload in ((self.create, self.desired), (self.update, {"contact_id": "contact-1", "expected_revision": "c" * 64, **self.desired})):
            for code, expected in (
                ("CONTACTS_TARGET_STALE", "MODEL_CORRECTABLE_FAILURE"),
                ("CONTACTS_UPDATE_UNSUPPORTED", "MODEL_CORRECTABLE_FAILURE"),
                ("CONTACTS_PERMISSION_RESTRICTED", "TERMINAL_FAILURE"),
                ("CONTACTS_SAVE_FAILED", "TERMINAL_FAILURE"),
            ):
                with self.subTest(adapter=adapter.capability_id, code=code):
                    verdict = adapter.verify_result(
                        self.action(payload), success=False, output={"error_code": code}, error=None
                    )
                    self.assertEqual(verdict.outcome, expected)


if __name__ == "__main__":
    unittest.main()
