import Contacts
import XCTest
@testable import Floweroll


actor FakeContactsQueryClient: ContactsQueryClient {
    private var statuses: [ContactsAuthorizationScope]
    private let searchIDs: [String]
    private let contacts: [String: ContactsContactSnapshot]
    private(set) var requestedSearchLimit: Int?
    private(set) var exactRequests: [String] = []

    init(
        statuses: [ContactsAuthorizationScope],
        searchIDs: [String] = [],
        contacts: [String: ContactsContactSnapshot] = [:]
    ) {
        self.statuses = statuses
        self.searchIDs = searchIDs
        self.contacts = contacts
    }

    func authorizationStatus() async -> ContactsAuthorizationScope {
        guard !statuses.isEmpty else { return .unknown }
        if statuses.count == 1 { return statuses[0] }
        return statuses.removeFirst()
    }

    func searchContactIDs(name: String, limit: Int) async throws -> [String] {
        requestedSearchLimit = limit
        return Array(searchIDs.prefix(limit))
    }

    func exactContact(id: String) async throws -> ContactsContactSnapshot? {
        exactRequests.append(id)
        return contacts[id]
    }
}


actor FakeContactsManagementClient: ContactsManagementClient {
    var status: ContactsAuthorizationScope = .authorized
    var managed: [String: ContactsManagedSnapshot] = [:]
    var createdReadbacks: [String: ContactsMutationReadback] = [:]
    var preparedID = "created-contact-1"
    var createCommit: ContactsMutationReadback?
    var updateCommit: ContactsMutationReadback?
    var createError: ContactsMutationClientError?
    var updateError: ContactsMutationClientError?
    private(set) var prepareCount = 0
    private(set) var createCommitCount = 0
    private(set) var updateCommitCount = 0
    private(set) var createdReadCount = 0

    func authorizationStatus() async -> ContactsAuthorizationScope { status }
    func managedContact(id: String) async throws -> ContactsManagedSnapshot? { managed[id] }

    func prepareCreate(attemptID: String, desired: ContactsDesiredContact) async throws -> String {
        prepareCount += 1
        return preparedID
    }

    func commitPreparedCreate(
        attemptID: String,
        expectedContactID: String,
        desired: ContactsDesiredContact
    ) async throws -> ContactsMutationReadback {
        createCommitCount += 1
        if let createError { throw createError }
        guard let createCommit else {
            throw ContactsMutationClientError.ambiguousReadback("fake create missing")
        }
        return createCommit
    }

    func readCreatedContact(id: String, desired: ContactsDesiredContact) async throws -> ContactsMutationReadback? {
        createdReadCount += 1
        return createdReadbacks[id]
    }

    func commitUpdate(
        id: String,
        expectedRevision: String,
        desired: ContactsDesiredContact
    ) async throws -> ContactsMutationReadback {
        updateCommitCount += 1
        if let updateError { throw updateError }
        guard let updateCommit else {
            throw ContactsMutationClientError.ambiguousReadback("fake update missing")
        }
        return updateCommit
    }
}


@MainActor
final class ContactsQueryExecutorTests: XCTestCase {
    private func dispatch(_ payload: [String: JSONValue]) -> DeviceActionDispatch {
        DeviceActionDispatch(
            actionID: "contacts-action",
            taskID: "contacts-task",
            actionType: "contacts.query",
            payload: payload,
            status: "executing",
            runtimeActionStatus: "executing",
            idempotencyKey: "contacts-idempotency",
            attemptID: "contacts-attempt",
            attemptNumber: 1,
            attemptStatus: "IN_FLIGHT",
            dispatchDigest: "contacts-digest"
        )
    }

    private func contact(
        requestedID: String,
        canonicalID: String? = nil,
        linked: Bool = true
    ) -> ContactsContactSnapshot {
        let resolvedID = canonicalID ?? requestedID
        let updateEligible = resolvedID == requestedID && linked
        return ContactsContactSnapshot(
            requestedContactID: requestedID,
            contactID: resolvedID,
            requestedIDLinkedIntoResult: linked,
            contactType: "person",
            displayName: "Ada Lovelace",
            givenName: "Ada",
            familyName: "Lovelace",
            organizationName: "Analytical Engine",
            phoneNumbers: [
                .init(label: "mobile", value: "+86 138 1234 5678"),
                .init(label: "work", value: "010-12345678"),
            ],
            emailAddresses: [
                .init(label: "work", value: "ada@example.com")
            ],
            revision: updateEligible ? String(repeating: "a", count: 64) : nil,
            updateEligible: updateEligible,
            updateIneligibleReason: updateEligible ? nil : "linked_contact_unsupported",
            containerResolution: updateEligible ? "single_backing_record" : "linked_or_ambiguous"
        )
    }

    func testPreflightNeverFetchesWhenPermissionIsNotGranted() async throws {
        for scope in [
            ContactsAuthorizationScope.notDetermined,
            .denied,
            .restricted,
            .unknown,
        ] {
            let client = FakeContactsQueryClient(statuses: [scope])
            let result = try await ContactsQueryExecutor(client: client).preflight(
                dispatch(["name_query": .string("Ada")])
            )
            XCTAssertFalse(result?.success ?? true, "scope=\(scope)")
            XCTAssertNotNil(result?.output["error_code"]?.stringValue)
            let requestedLimit = await client.requestedSearchLimit
            let exactRequests = await client.exactRequests
            XCTAssertNil(requestedLimit)
            XCTAssertTrue(exactRequests.isEmpty)
        }
    }

    func testNameQueryIsBoundedExactRefetchedAndMasksContactMethods() async throws {
        let ids = ["a", "b", "c"]
        let client = FakeContactsQueryClient(
            statuses: [.authorized],
            searchIDs: ids,
            contacts: Dictionary(uniqueKeysWithValues: ids.map { ($0, contact(requestedID: $0)) })
        )
        let result = try await ContactsQueryExecutor(client: client).execute(
            dispatch(["name_query": .string("Ada"), "max_results": .number(2)])
        )

        XCTAssertTrue(result.success)
        let requestedLimit = await client.requestedSearchLimit
        let exactRequests = await client.exactRequests
        XCTAssertEqual(requestedLimit, 3)
        XCTAssertEqual(exactRequests, ["a", "b"])
        XCTAssertEqual(result.output["query_mode"]?.stringValue, "name")
        XCTAssertEqual(result.output["truncated"]?.boolValue, true)
        let rows = try XCTUnwrap(result.output["contacts"]?.arrayValue)
        XCTAssertEqual(rows.count, 2)
        let first = try XCTUnwrap(rows.first?.objectValue)
        XCTAssertNil(first["phone_numbers"])
        XCTAssertNil(first["email_addresses"])
        XCTAssertEqual(first["phone_hints"]?.arrayValue?.first?.stringValue, "••••5678")
        XCTAssertEqual(first["email_hints"]?.arrayValue?.first?.stringValue, "a•••@example.com")
    }

    func testExactQueryReturnsBoundedFullMethodsAndCanonicalAliasProof() async throws {
        let client = FakeContactsQueryClient(
            statuses: [.authorized],
            contacts: ["old": contact(requestedID: "old", canonicalID: "fresh", linked: true)]
        )
        let result = try await ContactsQueryExecutor(client: client).execute(
            dispatch(["contact_id": .string("old")])
        )

        XCTAssertTrue(result.success)
        let rows = try XCTUnwrap(result.output["contacts"]?.arrayValue)
        let first = try XCTUnwrap(rows.first?.objectValue)
        XCTAssertEqual(first["contact_id"]?.stringValue, "fresh")
        XCTAssertEqual(first["canonicalized"]?.boolValue, true)
        XCTAssertEqual(first["requested_id_linked_into_result"]?.boolValue, true)
        XCTAssertEqual(first["update_eligible"]?.boolValue, false)
        XCTAssertNil(first["revision"]?.stringValue)
        XCTAssertEqual(first["phone_numbers"]?.arrayValue?.count, 2)
        XCTAssertEqual(first["email_addresses"]?.arrayValue?.count, 1)
    }

    func testExactCanonicalizationWithoutAliasProofFailsClosed() async throws {
        let client = FakeContactsQueryClient(
            statuses: [.authorized],
            contacts: ["old": contact(requestedID: "old", canonicalID: "fresh", linked: false)]
        )
        let result = try await ContactsQueryExecutor(client: client).execute(
            dispatch(["contact_id": .string("old")])
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output["error_code"]?.stringValue, "CONTACTS_STORE_CHANGED_RETRY_SAFE")
    }

    func testLimitedEmptyNeverClaimsGlobalAbsence() async throws {
        let client = FakeContactsQueryClient(statuses: [.limited], searchIDs: [])
        let result = try await ContactsQueryExecutor(client: client).execute(
            dispatch(["name_query": .string("Ada")])
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output["authorization_scope"]?.stringValue, "limited")
        XCTAssertEqual(result.output["found"]?.boolValue, false)
        XCTAssertEqual(result.output["empty_reason"]?.stringValue, "not_accessible_or_not_found")
    }

    func testPermissionChangeDuringReadFailsWithoutReturningStaleContactData() async throws {
        let client = FakeContactsQueryClient(
            statuses: [.authorized, .denied],
            contacts: ["a": contact(requestedID: "a")]
        )
        let result = try await ContactsQueryExecutor(client: client).execute(
            dispatch(["contact_id": .string("a")])
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output["error_code"]?.stringValue, "CONTACTS_PERMISSION_DENIED")
        XCTAssertNil(result.output["contacts"])
    }
}

extension FakeContactsManagementClient {
    func setManaged(_ snapshot: ContactsManagedSnapshot, for id: String) { managed[id] = snapshot }
    func setCreatedReadback(_ readback: ContactsMutationReadback, for id: String) { createdReadbacks[id] = readback }
    func setValueForCreate(_ readback: ContactsMutationReadback?) { createCommit = readback }
    func setValueForUpdate(_ readback: ContactsMutationReadback?) { updateCommit = readback }
    func setCreateError(_ error: ContactsMutationClientError?) { createError = error }
    func setUpdateError(_ error: ContactsMutationClientError?) { updateError = error }
}


@MainActor
final class ContactsManagementExecutorTests: XCTestCase {
    private func desired() -> ContactsDesiredContact {
        ContactsDesiredContact(
            givenName: "Ada",
            familyName: "Lovelace",
            organizationName: "Analytical Engine",
            phoneNumbers: [.init(label: "mobile", value: "+1 555 0100")],
            emailAddresses: [.init(label: "work", value: "ada@example.com")]
        )
    }

    private func payload(_ desired: ContactsDesiredContact) -> [String: JSONValue] {
        [
            "given_name": .string(desired.givenName),
            "family_name": .string(desired.familyName),
            "organization_name": .string(desired.organizationName),
            "phone_numbers": .array(desired.phoneNumbers.map { .object(["label": .string($0.label), "value": .string($0.value)]) }),
            "email_addresses": .array(desired.emailAddresses.map { .object(["label": .string($0.label), "value": .string($0.value)]) }),
        ]
    }

    private func dispatch(
        _ actionType: String,
        payload: [String: JSONValue],
        attemptID: String = UUID().uuidString
    ) -> DeviceActionDispatch {
        DeviceActionDispatch(
            actionID: "contacts-management-action",
            taskID: "contacts-management-task",
            actionType: actionType,
            payload: payload,
            status: "executing",
            runtimeActionStatus: "executing",
            idempotencyKey: "contacts-management-idem",
            attemptID: attemptID,
            attemptNumber: 1,
            attemptStatus: "IN_FLIGHT",
            dispatchDigest: "contacts-management-digest"
        )
    }

    private func snapshot(
        id: String,
        desired: ContactsDesiredContact? = nil,
        revision: String? = String(repeating: "a", count: 64),
        updateEligible: Bool = true,
        reason: String? = nil
    ) -> ContactsManagedSnapshot {
        ContactsManagedSnapshot(
            requestedContactID: id,
            contactID: id,
            requestedIDLinkedIntoResult: true,
            contactType: "person",
            displayName: "Ada Lovelace",
            desired: desired ?? self.desired(),
            revision: updateEligible ? revision : nil,
            updateEligible: updateEligible,
            updateIneligibleReason: updateEligible ? nil : (reason ?? "linked_contact_unsupported"),
            containerResolution: updateEligible ? "single_backing_record" : "linked_or_ambiguous"
        )
    }

    private func tempRecoveryStore() -> ContactsCreateRecoveryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("contacts-create-recovery-\(UUID().uuidString).json")
        return ContactsCreateRecoveryStore(fileURL: url)
    }

    func testCreateRecoveryStoreReloadsIso8601Record() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("contacts-create-reload-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ContactsCreateRecoveryStore(fileURL: url)
        try await first.prepare(
            attemptID: "attempt-reload",
            contactID: "native-reload-id",
            desiredDigest: String(repeating: "d", count: 64)
        )
        let second = ContactsCreateRecoveryStore(fileURL: url)
        let restored = try await second.record(for: "attempt-reload")
        XCTAssertEqual(restored?.contactID, "native-reload-id")
        XCTAssertEqual(restored?.desiredDigest, String(repeating: "d", count: 64))
    }

    func testCorruptCreateRecoveryLedgerFailsClosedBeforePreparingAnotherContact() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("contacts-create-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not-json".utf8).write(to: url, options: .atomic)

        let desired = desired()
        let client = FakeContactsManagementClient()
        let store = ContactsCreateRecoveryStore(fileURL: url)
        let executor = ContactsCreateExecutor(client: client, recoveryStore: store)
        let action = dispatch(
            "contacts.create",
            payload: payload(desired),
            attemptID: "attempt-corrupt-recovery"
        )

        do {
            _ = try await executor.execute(action)
            XCTFail("corrupt recovery ledger must not be treated as an empty healthy ledger")
        } catch let error as ContactsMutationClientError {
            guard case .ambiguousReadback = error else {
                return XCTFail("unexpected contacts error: \(error)")
            }
        }

        let prepareCount = await client.prepareCount
        let createCommitCount = await client.createCommitCount
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(createCommitCount, 0)

        let now = Date()
        let journal = DeviceActionJournalEntry(
            attemptID: action.attemptID,
            actionID: action.actionID,
            idempotencyKey: action.idempotencyKey,
            dispatchDigest: action.dispatchDigest,
            state: .mayHaveStarted,
            success: nil,
            result: nil,
            error: nil,
            nativeCorrelationID: nil,
            createdAt: now,
            updatedAt: now
        )
        let reconciled = try await executor.reconcile(action, journalEntry: journal)
        guard case .stillUnknown = reconciled else {
            return XCTFail("corrupt recovery ledger must remain unknown during reconciliation")
        }
    }

    func testCustomNativeMethodLabelsAreNotUpdateEligible() {
        let contact = CNMutableContact()
        contact.givenName = "Custom"
        contact.phoneNumbers = [
            CNLabeledValue(label: "X-CUSTOM", value: CNPhoneNumber(stringValue: "12345"))
        ]
        XCTAssertFalse(ContactsFieldCodec.hasOnlySupportedMethodLabels(contact))

        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "12345"))
        ]
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "a@example.com" as NSString)
        ]
        XCTAssertTrue(ContactsFieldCodec.hasOnlySupportedMethodLabels(contact))
    }

    func testCreatePersistsNativeIDAndSameAttemptNeverBlindCreatesAgain() async throws {
        let desired = desired()
        let client = FakeContactsManagementClient()
        let createdSnapshot = snapshot(id: "created-contact-1", desired: desired)
        let readback = ContactsMutationReadback(
            snapshot: createdSnapshot,
            applied: true,
            createdContactID: "created-contact-1"
        )
        await client.setValueForCreate(readback)
        let store = tempRecoveryStore()
        let executor = ContactsCreateExecutor(client: client, recoveryStore: store)
        let action = dispatch("contacts.create", payload: payload(desired), attemptID: "attempt-create-1")

        let createPreflight = try await executor.preflight(action)
        XCTAssertNil(createPreflight)
        let first = try await executor.execute(action)
        XCTAssertTrue(first.success)
        XCTAssertEqual(first.output["created_contact_id"]?.stringValue, "created-contact-1")
        let firstPrepareCount = await client.prepareCount
        let firstCreateCommitCount = await client.createCommitCount
        XCTAssertEqual(firstPrepareCount, 1)
        XCTAssertEqual(firstCreateCommitCount, 1)

        await client.setCreatedReadback(readback, for: "created-contact-1")
        let replay = try await executor.execute(action)
        XCTAssertTrue(replay.success)
        let replayPrepareCount = await client.prepareCount
        let replayCreateCommitCount = await client.createCommitCount
        let replayReadCount = await client.createdReadCount
        XCTAssertEqual(replayPrepareCount, 1, "same durable attempt must not prepare another native contact")
        XCTAssertEqual(replayCreateCommitCount, 1, "same durable attempt must not execute another CNSaveRequest")
        XCTAssertEqual(replayReadCount, 1)
    }

    func testCreateNativeSaveFailureRemainsAmbiguousForCoordinatorReconciliation() async throws {
        let desired = desired()
        let client = FakeContactsManagementClient()
        await client.setCreateError(.nativeSaveFailed("simulated contacts write error"))
        let executor = ContactsCreateExecutor(client: client, recoveryStore: tempRecoveryStore())
        let action = dispatch("contacts.create", payload: payload(desired), attemptID: "attempt-create-native-error")

        do {
            _ = try await executor.execute(action)
            XCTFail("native save failure after may-have-started must stay ambiguous")
        } catch let error as ContactsMutationClientError {
            guard case .nativeSaveFailed = error else {
                return XCTFail("unexpected contacts error: \(error)")
            }
        }
    }

    func testCreateOrphanedMayHaveStartedStaysUnknownAndDoesNotPrepareAgain() async throws {
        let desired = desired()
        let client = FakeContactsManagementClient()
        let store = tempRecoveryStore()
        let attemptID = "attempt-orphaned-create"
        try await store.prepare(
            attemptID: attemptID,
            contactID: "prepared-native-id",
            desiredDigest: ContactsRevisionCodec.desiredDigest(desired)
        )
        let executor = ContactsCreateExecutor(client: client, recoveryStore: store)
        let action = dispatch("contacts.create", payload: payload(desired), attemptID: attemptID)
        do {
            _ = try await executor.execute(action)
            XCTFail("orphaned create must not silently create a second contact")
        } catch {
            let prepareCount = await client.prepareCount
            let createCount = await client.createCommitCount
            XCTAssertEqual(prepareCount, 0)
            XCTAssertEqual(createCount, 0)
        }
    }

    func testUpdatePreflightRejectsLinkedContactAndStaleRevisionBeforeSave() async throws {
        let desired = desired()
        let client = FakeContactsManagementClient()
        let executor = ContactsUpdateExecutor(client: client)

        await client.setManaged(
            snapshot(id: "linked", desired: desired, updateEligible: false, reason: "linked_contact_unsupported"),
            for: "linked"
        )
        var linkedPayload = payload(desired)
        linkedPayload["contact_id"] = .string("linked")
        linkedPayload["expected_revision"] = .string(String(repeating: "a", count: 64))
        let linkedResult = try await executor.preflight(dispatch("contacts.update", payload: linkedPayload))
        XCTAssertEqual(linkedResult?.output["error_code"]?.stringValue, "CONTACTS_UPDATE_UNSUPPORTED")
        let linkedUpdateCount = await client.updateCommitCount
        XCTAssertEqual(linkedUpdateCount, 0)

        await client.setManaged(snapshot(id: "fresh", desired: desired, revision: String(repeating: "b", count: 64)), for: "fresh")
        var stalePayload = payload(desired)
        stalePayload["contact_id"] = .string("fresh")
        stalePayload["expected_revision"] = .string(String(repeating: "a", count: 64))
        let staleResult = try await executor.preflight(dispatch("contacts.update", payload: stalePayload))
        XCTAssertEqual(staleResult?.output["error_code"]?.stringValue, "CONTACTS_TARGET_STALE")
        let staleUpdateCount = await client.updateCommitCount
        XCTAssertEqual(staleUpdateCount, 0)
    }

    func testUpdateNativeSaveFailureRemainsAmbiguousForCoordinatorReconciliation() async throws {
        let desired = desired()
        let client = FakeContactsManagementClient()
        let current = snapshot(id: "contact-native-error", desired: desired, revision: String(repeating: "a", count: 64))
        await client.setManaged(current, for: "contact-native-error")
        await client.setUpdateError(.nativeSaveFailed("simulated contacts update error"))
        let executor = ContactsUpdateExecutor(client: client)
        var updatePayload = payload(desired)
        updatePayload["contact_id"] = .string("contact-native-error")
        updatePayload["expected_revision"] = .string(String(repeating: "a", count: 64))
        let action = dispatch("contacts.update", payload: updatePayload, attemptID: "attempt-update-native-error")

        do {
            _ = try await executor.execute(action)
            XCTFail("native update failure after may-have-started must stay ambiguous")
        } catch let error as ContactsMutationClientError {
            guard case .nativeSaveFailed = error else {
                return XCTFail("unexpected contacts error: \(error)")
            }
        }
    }

    func testUpdateSuccessAndReadOnlyReconciliationUseExactDesiredState() async throws {
        let desired = desired()
        let client = FakeContactsManagementClient()
        let current = snapshot(id: "contact-1", desired: desired, revision: String(repeating: "a", count: 64))
        await client.setManaged(current, for: "contact-1")
        await client.setValueForUpdate(ContactsMutationReadback(snapshot: current, applied: true, createdContactID: nil))
        let executor = ContactsUpdateExecutor(client: client)
        var updatePayload = payload(desired)
        updatePayload["contact_id"] = .string("contact-1")
        updatePayload["expected_revision"] = .string(String(repeating: "a", count: 64))
        let action = dispatch("contacts.update", payload: updatePayload, attemptID: "attempt-update")

        let updatePreflight = try await executor.preflight(action)
        XCTAssertNil(updatePreflight)
        let result = try await executor.execute(action)
        XCTAssertTrue(result.success)
        let updateCount = await client.updateCommitCount
        XCTAssertEqual(updateCount, 1)

        let now = Date()
        let journal = DeviceActionJournalEntry(
            attemptID: action.attemptID,
            actionID: action.actionID,
            idempotencyKey: action.idempotencyKey,
            dispatchDigest: action.dispatchDigest,
            state: .mayHaveStarted,
            success: nil,
            result: nil,
            error: nil,
            nativeCorrelationID: nil,
            createdAt: now,
            updatedAt: now
        )
        let reconciled = try await executor.reconcile(action, journalEntry: journal)
        switch reconciled {
        case let .completed(value):
            XCTAssertTrue(value.success)
            XCTAssertEqual(value.output["contact_id"]?.stringValue, "contact-1")
        default:
            XCTFail("matching exact desired state should reconcile completed")
        }
    }

    func testSystemContactsCreateQueryUpdateCleanupWhenExplicitlyEnabled() async throws {
        let marker = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Floweroll/contacts-system-integration-enabled")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("system Contacts integration requires an explicit Simulator-only marker")
        }
        guard ContactsAuthorizationScope.current().allowsQuery else {
            throw XCTSkip("Simulator Contacts authorization is not granted")
        }

        let unique = UUID().uuidString.prefix(8)
        let initial = ContactsDesiredContact(
            givenName: "Floweroll",
            familyName: "Synthetic-\(unique)",
            organizationName: "Floweroll Test",
            phoneNumbers: [.init(label: "mobile", value: "+1 555 01\(Int.random(in: 10...99))")],
            emailAddresses: [.init(label: "work", value: "contacts-\(unique.lowercased())@example.com")]
        )
        let client = SystemContactsManagementClient()
        let attemptID = "system-create-\(UUID().uuidString)"
        let createdID = try await client.prepareCreate(attemptID: attemptID, desired: initial)
        defer { try? Self.deleteSyntheticContact(identifier: createdID) }

        let created = try await client.commitPreparedCreate(
            attemptID: attemptID,
            expectedContactID: createdID,
            desired: initial
        )
        XCTAssertEqual(created.createdContactID, createdID)
        XCTAssertEqual(created.snapshot.desired, initial)
        XCTAssertTrue(created.snapshot.requestedIDLinkedIntoResult)

        let queryClient = SystemContactsQueryClient()
        let queriedValue = try await queryClient.exactContact(id: created.snapshot.contactID)
        let queried = try XCTUnwrap(queriedValue)
        XCTAssertEqual(queried.givenName, initial.givenName)
        XCTAssertEqual(queried.familyName, initial.familyName)
        XCTAssertEqual(queried.organizationName, initial.organizationName)
        XCTAssertTrue(queried.updateEligible)
        let revision = try XCTUnwrap(queried.revision)

        let updatedDesired = ContactsDesiredContact(
            givenName: initial.givenName,
            familyName: initial.familyName,
            organizationName: "Floweroll Updated",
            phoneNumbers: initial.phoneNumbers,
            emailAddresses: [
                .init(label: "work", value: "updated-\(unique.lowercased())@example.com")
            ]
        )
        let updated = try await client.commitUpdate(
            id: queried.contactID,
            expectedRevision: revision,
            desired: updatedDesired
        )
        XCTAssertTrue(updated.applied)
        XCTAssertEqual(updated.snapshot.contactID, queried.contactID)
        XCTAssertEqual(updated.snapshot.desired, updatedDesired)
        XCTAssertNotEqual(updated.snapshot.revision, revision)

        let finalQueryValue = try await queryClient.exactContact(id: queried.contactID)
        let finalQuery = try XCTUnwrap(finalQueryValue)
        XCTAssertEqual(finalQuery.organizationName, updatedDesired.organizationName)
        XCTAssertEqual(finalQuery.emailAddresses, updatedDesired.emailAddresses)
        XCTAssertTrue(finalQuery.updateEligible)
    }

    private static func deleteSyntheticContact(identifier: String) throws {
        let store = CNContactStore()
        let request = CNContactFetchRequest(
            keysToFetch: [CNContactIdentifierKey as any CNKeyDescriptor]
        )
        request.predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
        request.unifyResults = false
        request.mutableObjects = true
        var exact: CNMutableContact?
        try store.enumerateContacts(with: request) { contact, stop in
            if contact.identifier == identifier, let mutable = contact as? CNMutableContact {
                exact = mutable
                stop.pointee = true
            }
        }
        guard let exact else { return }
        let save = CNSaveRequest()
        save.delete(exact)
        try store.execute(save)
    }

}
