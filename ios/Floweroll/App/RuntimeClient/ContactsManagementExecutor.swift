import Contacts
import CryptoKit
import Foundation


struct ContactsDesiredContact: Codable, Equatable, Sendable {
    let givenName: String
    let familyName: String
    let organizationName: String
    let phoneNumbers: [ContactsLabeledValueSnapshot]
    let emailAddresses: [ContactsLabeledValueSnapshot]

    var hasMeaningfulContent: Bool {
        !givenName.isEmpty
            || !familyName.isEmpty
            || !organizationName.isEmpty
            || !phoneNumbers.isEmpty
            || !emailAddresses.isEmpty
    }
}


struct ContactsManagedSnapshot: Equatable, Sendable {
    let requestedContactID: String
    let contactID: String
    let requestedIDLinkedIntoResult: Bool
    let contactType: String
    let displayName: String
    let desired: ContactsDesiredContact
    let revision: String?
    let updateEligible: Bool
    let updateIneligibleReason: String?
    let containerResolution: String
}


struct ContactsMutationReadback: Equatable, Sendable {
    let snapshot: ContactsManagedSnapshot
    let applied: Bool
    let createdContactID: String?
}


enum ContactsMutationClientError: Error, LocalizedError, Sendable {
    case preparedContactMissing
    case generatedIdentifierMissing
    case targetNotAccessible
    case targetStale
    case updateUnsupported(String)
    case nativeSaveFailed(String)
    case ambiguousReadback(String)

    var errorDescription: String? {
        switch self {
        case .preparedContactMissing:
            return "联系人创建准备状态已丢失。"
        case .generatedIdentifierMissing:
            return "系统没有为新联系人提供可恢复的标识。"
        case .targetNotAccessible:
            return "目标联系人当前不可访问，请重新查询。"
        case .targetStale:
            return "联系人在修改前已经变化，请重新查询。"
        case let .updateUnsupported(reason):
            return "这个联系人当前不能安全修改：\(reason)"
        case let .nativeSaveFailed(message):
            return message
        case let .ambiguousReadback(message):
            return message
        }
    }
}


enum ContactsFieldCodec {
    enum MethodKind { case phone, email }

    static func stableLabel(_ raw: String?, kind: MethodKind) -> String {
        switch raw {
        case CNLabelHome:
            return "home"
        case CNLabelWork:
            return "work"
        case CNLabelPhoneNumberMobile where kind == .phone:
            return "mobile"
        case CNLabelPhoneNumberiPhone where kind == .phone:
            return "mobile"
        default:
            return "other"
        }
    }

    static func isSupportedNativeLabel(_ raw: String?, kind: MethodKind) -> Bool {
        switch kind {
        case .phone:
            return raw == CNLabelPhoneNumberMobile
                || raw == CNLabelPhoneNumberiPhone
                || raw == CNLabelHome
                || raw == CNLabelWork
                || raw == CNLabelOther
        case .email:
            return raw == CNLabelHome || raw == CNLabelWork || raw == CNLabelOther
        }
    }

    static func hasOnlySupportedMethodLabels(_ contact: CNContact) -> Bool {
        contact.phoneNumbers.allSatisfy { isSupportedNativeLabel($0.label, kind: .phone) }
            && contact.emailAddresses.allSatisfy { isSupportedNativeLabel($0.label, kind: .email) }
    }

    static func nativeLabel(_ stable: String, kind: MethodKind) -> String? {
        switch (kind, stable) {
        case (.phone, "mobile"):
            return CNLabelPhoneNumberMobile
        case (_, "home"):
            return CNLabelHome
        case (_, "work"):
            return CNLabelWork
        case (_, "other"):
            return CNLabelOther
        default:
            return nil
        }
    }

    static func phoneSnapshots(_ contact: CNContact) -> [ContactsLabeledValueSnapshot] {
        contact.phoneNumbers.map { labeled in
            ContactsLabeledValueSnapshot(
                label: stableLabel(labeled.label, kind: .phone),
                value: labeled.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func emailSnapshots(_ contact: CNContact) -> [ContactsLabeledValueSnapshot] {
        contact.emailAddresses.map { labeled in
            ContactsLabeledValueSnapshot(
                label: stableLabel(labeled.label, kind: .email),
                value: String(labeled.value).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static func desired(from contact: CNContact) -> ContactsDesiredContact {
        ContactsDesiredContact(
            givenName: contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines),
            familyName: contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines),
            organizationName: contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines),
            phoneNumbers: phoneSnapshots(contact),
            emailAddresses: emailSnapshots(contact)
        )
    }

    static func apply(_ desired: ContactsDesiredContact, to contact: CNMutableContact) {
        contact.contactType = .person
        contact.givenName = desired.givenName
        contact.familyName = desired.familyName
        contact.organizationName = desired.organizationName
        contact.phoneNumbers = desired.phoneNumbers.compactMap { item in
            guard let label = nativeLabel(item.label, kind: .phone) else { return nil }
            return CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: item.value))
        }
        contact.emailAddresses = desired.emailAddresses.compactMap { item in
            guard let label = nativeLabel(item.label, kind: .email) else { return nil }
            return CNLabeledValue(label: label, value: item.value as NSString)
        }
    }

    static func displayName(for contact: CNContact) -> String {
        let formatted = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let formatted, !formatted.isEmpty { return formatted }
        let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return organization.isEmpty ? "未命名联系人" : organization
    }
}


enum ContactsRevisionCodec {
    private struct RevisionEnvelope: Codable {
        let contactID: String
        let containerID: String
        let contactType: String
        let desired: ContactsDesiredContact
    }

    static func revision(contactID: String, containerID: String, contact: CNContact) -> String {
        let envelope = RevisionEnvelope(
            contactID: contactID,
            containerID: containerID,
            contactType: contact.contactType == .organization ? "organization" : "person",
            desired: ContactsFieldCodec.desired(from: contact)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(envelope)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func desiredDigest(_ desired: ContactsDesiredContact) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(desired)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}


enum ContactsNativeManagementReader {
    static func managementKeys() -> [any CNKeyDescriptor] {
        [
            CNContactIdentifierKey as any CNKeyDescriptor,
            CNContactTypeKey as any CNKeyDescriptor,
            CNContactGivenNameKey as any CNKeyDescriptor,
            CNContactFamilyNameKey as any CNKeyDescriptor,
            CNContactOrganizationNameKey as any CNKeyDescriptor,
            CNContactPhoneNumbersKey as any CNKeyDescriptor,
            CNContactEmailAddressesKey as any CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
    }

    static func individualContact(
        store: CNContactStore,
        identifier: String,
        mutable: Bool
    ) throws -> CNContact? {
        let request = CNContactFetchRequest(keysToFetch: managementKeys())
        request.predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
        request.unifyResults = false
        request.mutableObjects = mutable
        var matches: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, stop in
            matches.append(contact)
            if matches.count > 1 { stop.pointee = true }
        }
        guard matches.count == 1, matches[0].identifier == identifier else { return nil }
        return matches[0]
    }

    static func containerID(store: CNContactStore, individualContactID: String) throws -> String? {
        let predicate = CNContainer.predicateForContainerOfContact(withIdentifier: individualContactID)
        let containers = try store.containers(matching: predicate)
        guard containers.count == 1 else { return nil }
        return containers[0].identifier
    }

    static func managedSnapshot(
        store: CNContactStore,
        requestedID: String
    ) throws -> ContactsManagedSnapshot? {
        let unified: CNContact
        do {
            unified = try store.unifiedContact(withIdentifier: requestedID, keysToFetch: managementKeys())
        } catch {
            let nsError = error as NSError
            if nsError.domain == CNErrorDomain,
               nsError.code == CNError.Code.recordDoesNotExist.rawValue {
                return nil
            }
            throw error
        }

        let linked = unified.identifier == requestedID || unified.isUnifiedWithContact(withIdentifier: requestedID)
        let baseDesired = ContactsFieldCodec.desired(from: unified)
        let base = ContactsManagedSnapshot(
            requestedContactID: requestedID,
            contactID: unified.identifier,
            requestedIDLinkedIntoResult: linked,
            contactType: unified.contactType == .organization ? "organization" : "person",
            displayName: ContactsFieldCodec.displayName(for: unified),
            desired: baseDesired,
            revision: nil,
            updateEligible: false,
            updateIneligibleReason: "unresolved_backing_record",
            containerResolution: "unresolved"
        )

        guard linked else { return base }
        guard unified.contactType == .person else {
            return ContactsManagedSnapshot(
                requestedContactID: base.requestedContactID,
                contactID: base.contactID,
                requestedIDLinkedIntoResult: base.requestedIDLinkedIntoResult,
                contactType: base.contactType,
                displayName: base.displayName,
                desired: base.desired,
                revision: nil,
                updateEligible: false,
                updateIneligibleReason: "organization_contact_unsupported",
                containerResolution: "unresolved"
            )
        }
        guard ContactsFieldCodec.hasOnlySupportedMethodLabels(unified) else {
            return ContactsManagedSnapshot(
                requestedContactID: base.requestedContactID,
                contactID: base.contactID,
                requestedIDLinkedIntoResult: base.requestedIDLinkedIntoResult,
                contactType: base.contactType,
                displayName: base.displayName,
                desired: base.desired,
                revision: nil,
                updateEligible: false,
                updateIneligibleReason: "custom_contact_method_labels_unsupported",
                containerResolution: "unresolved"
            )
        }
        guard unified.identifier == requestedID else {
            return ContactsManagedSnapshot(
                requestedContactID: base.requestedContactID,
                contactID: base.contactID,
                requestedIDLinkedIntoResult: base.requestedIDLinkedIntoResult,
                contactType: base.contactType,
                displayName: base.displayName,
                desired: base.desired,
                revision: nil,
                updateEligible: false,
                updateIneligibleReason: "linked_contact_unsupported",
                containerResolution: "linked_or_ambiguous"
            )
        }
        guard let containerID = try containerID(store: store, individualContactID: unified.identifier),
              let individual = try individualContact(store: store, identifier: unified.identifier, mutable: false) else {
            return ContactsManagedSnapshot(
                requestedContactID: base.requestedContactID,
                contactID: base.contactID,
                requestedIDLinkedIntoResult: base.requestedIDLinkedIntoResult,
                contactType: base.contactType,
                displayName: base.displayName,
                desired: base.desired,
                revision: nil,
                updateEligible: false,
                updateIneligibleReason: "linked_or_ambiguous_backing_record",
                containerResolution: "linked_or_ambiguous"
            )
        }
        let revision = ContactsRevisionCodec.revision(
            contactID: individual.identifier,
            containerID: containerID,
            contact: individual
        )
        return ContactsManagedSnapshot(
            requestedContactID: requestedID,
            contactID: unified.identifier,
            requestedIDLinkedIntoResult: true,
            contactType: "person",
            displayName: ContactsFieldCodec.displayName(for: individual),
            desired: ContactsFieldCodec.desired(from: individual),
            revision: revision,
            updateEligible: true,
            updateIneligibleReason: nil,
            containerResolution: "single_backing_record"
        )
    }

    static func createdContactReadback(
        store: CNContactStore,
        createdIndividualID: String,
        expected: ContactsDesiredContact
    ) throws -> ContactsMutationReadback? {
        guard let individual = try individualContact(
            store: store,
            identifier: createdIndividualID,
            mutable: false
        ), ContactsFieldCodec.desired(from: individual) == expected else {
            return nil
        }
        let unified: CNContact
        do {
            unified = try store.unifiedContact(
                withIdentifier: createdIndividualID,
                keysToFetch: managementKeys()
            )
        } catch {
            return nil
        }
        guard unified.identifier == createdIndividualID
                || unified.isUnifiedWithContact(withIdentifier: createdIndividualID) else {
            return nil
        }
        let managed = try managedSnapshot(store: store, requestedID: unified.identifier)
        let snapshot: ContactsManagedSnapshot
        if let managed {
            snapshot = ContactsManagedSnapshot(
                requestedContactID: createdIndividualID,
                contactID: unified.identifier,
                requestedIDLinkedIntoResult: true,
                contactType: "person",
                displayName: ContactsFieldCodec.displayName(for: individual),
                desired: expected,
                revision: managed.revision,
                updateEligible: managed.updateEligible,
                updateIneligibleReason: managed.updateIneligibleReason,
                containerResolution: managed.containerResolution
            )
        } else {
            snapshot = ContactsManagedSnapshot(
                requestedContactID: createdIndividualID,
                contactID: unified.identifier,
                requestedIDLinkedIntoResult: true,
                contactType: "person",
                displayName: ContactsFieldCodec.displayName(for: individual),
                desired: expected,
                revision: nil,
                updateEligible: false,
                updateIneligibleReason: "linked_or_ambiguous_backing_record",
                containerResolution: "linked_or_ambiguous"
            )
        }
        return ContactsMutationReadback(snapshot: snapshot, applied: true, createdContactID: createdIndividualID)
    }
}


protocol ContactsManagementClient: Sendable {
    func authorizationStatus() async -> ContactsAuthorizationScope
    func managedContact(id: String) async throws -> ContactsManagedSnapshot?
    func prepareCreate(attemptID: String, desired: ContactsDesiredContact) async throws -> String
    func commitPreparedCreate(
        attemptID: String,
        expectedContactID: String,
        desired: ContactsDesiredContact
    ) async throws -> ContactsMutationReadback
    func readCreatedContact(id: String, desired: ContactsDesiredContact) async throws -> ContactsMutationReadback?
    func commitUpdate(
        id: String,
        expectedRevision: String,
        desired: ContactsDesiredContact
    ) async throws -> ContactsMutationReadback
}


actor SystemContactsManagementClient: ContactsManagementClient {
    private let store: CNContactStore
    private var preparedCreates: [String: CNMutableContact] = [:]

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    func authorizationStatus() async -> ContactsAuthorizationScope {
        ContactsAuthorizationScope.current()
    }

    func managedContact(id: String) async throws -> ContactsManagedSnapshot? {
        try ContactsNativeManagementReader.managedSnapshot(store: store, requestedID: id)
    }

    func prepareCreate(attemptID: String, desired: ContactsDesiredContact) async throws -> String {
        if let existing = preparedCreates[attemptID] {
            return existing.identifier
        }
        let contact = CNMutableContact()
        ContactsFieldCodec.apply(desired, to: contact)
        let identifier = contact.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw ContactsMutationClientError.generatedIdentifierMissing }
        preparedCreates[attemptID] = contact
        return identifier
    }

    func commitPreparedCreate(
        attemptID: String,
        expectedContactID: String,
        desired: ContactsDesiredContact
    ) async throws -> ContactsMutationReadback {
        guard let contact = preparedCreates.removeValue(forKey: attemptID),
              contact.identifier == expectedContactID else {
            throw ContactsMutationClientError.preparedContactMissing
        }
        let request = CNSaveRequest()
        request.shouldRefetchContacts = true
        request.transactionAuthor = "com.maxenceyu.floweroll.contacts"
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw ContactsMutationClientError.nativeSaveFailed(error.localizedDescription)
        }
        guard let readback = try ContactsNativeManagementReader.createdContactReadback(
            store: store,
            createdIndividualID: expectedContactID,
            expected: desired
        ) else {
            throw ContactsMutationClientError.ambiguousReadback("联系人可能已经创建，但保存后的精确读回没有稳定完成。")
        }
        return readback
    }

    func readCreatedContact(id: String, desired: ContactsDesiredContact) async throws -> ContactsMutationReadback? {
        try ContactsNativeManagementReader.createdContactReadback(
            store: store,
            createdIndividualID: id,
            expected: desired
        )
    }

    func commitUpdate(
        id: String,
        expectedRevision: String,
        desired: ContactsDesiredContact
    ) async throws -> ContactsMutationReadback {
        guard let current = try ContactsNativeManagementReader.managedSnapshot(store: store, requestedID: id) else {
            throw ContactsMutationClientError.targetNotAccessible
        }
        guard current.contactID == id, current.updateEligible, let revision = current.revision else {
            throw ContactsMutationClientError.updateUnsupported(current.updateIneligibleReason ?? "linked_or_ambiguous")
        }
        if current.desired == desired {
            return ContactsMutationReadback(snapshot: current, applied: false, createdContactID: nil)
        }
        guard revision == expectedRevision else { throw ContactsMutationClientError.targetStale }
        guard let mutable = try ContactsNativeManagementReader.individualContact(
            store: store,
            identifier: id,
            mutable: true
        ) as? CNMutableContact,
              let containerID = try ContactsNativeManagementReader.containerID(
                store: store,
                individualContactID: id
              ) else {
            throw ContactsMutationClientError.updateUnsupported("linked_or_ambiguous_backing_record")
        }
        let finalRevision = ContactsRevisionCodec.revision(
            contactID: id,
            containerID: containerID,
            contact: mutable
        )
        guard finalRevision == expectedRevision else { throw ContactsMutationClientError.targetStale }
        ContactsFieldCodec.apply(desired, to: mutable)
        let request = CNSaveRequest()
        request.shouldRefetchContacts = true
        request.transactionAuthor = "com.maxenceyu.floweroll.contacts"
        request.update(mutable)
        do {
            try store.execute(request)
        } catch {
            throw ContactsMutationClientError.nativeSaveFailed(error.localizedDescription)
        }
        guard let readback = try ContactsNativeManagementReader.managedSnapshot(store: store, requestedID: id),
              readback.contactID == id,
              readback.updateEligible,
              readback.desired == desired else {
            throw ContactsMutationClientError.ambiguousReadback("联系人可能已经修改，但保存后的精确读回没有稳定完成。")
        }
        return ContactsMutationReadback(snapshot: readback, applied: true, createdContactID: nil)
    }
}


struct ContactsCreateRecoveryRecord: Codable, Equatable, Sendable {
    let attemptID: String
    let contactID: String
    let desiredDigest: String
    let preparedAt: Date
}


actor ContactsCreateRecoveryStore {
    static let shared = ContactsCreateRecoveryStore()

    private let fileURL: URL
    private var records: [String: ContactsCreateRecoveryRecord]
    private var loadFailed = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Floweroll/RuntimeClient", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("contacts-create-recovery.json")
        }
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
            records = [:]
            return
        }
        do {
            let data = try Data(contentsOf: self.fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([String: ContactsCreateRecoveryRecord].self, from: data)
        } catch {
            records = [:]
            loadFailed = true
        }
    }

    func record(for attemptID: String) throws -> ContactsCreateRecoveryRecord? {
        try assertHealthy()
        return records[attemptID]
    }

    func prepare(attemptID: String, contactID: String, desiredDigest: String) throws {
        try assertHealthy()
        if let existing = records[attemptID] {
            guard existing.contactID == contactID, existing.desiredDigest == desiredDigest else {
                throw ContactsMutationClientError.ambiguousReadback("联系人创建恢复标识与当前请求不一致。")
            }
            return
        }
        records[attemptID] = ContactsCreateRecoveryRecord(
            attemptID: attemptID,
            contactID: contactID,
            desiredDigest: desiredDigest,
            preparedAt: Date()
        )
        if records.count > 200 {
            let keep = records.values.sorted { $0.preparedAt > $1.preparedAt }.prefix(160)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.attemptID, $0) })
        }
        try persist()
    }

    private func assertHealthy() throws {
        guard !loadFailed else {
            throw ContactsMutationClientError.ambiguousReadback(
                "联系人创建恢复记录无法读取；为避免重复创建，不会继续执行。"
            )
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}


private enum ContactsMutationFailureCode: String {
    case invalid = "CONTACTS_MUTATION_INVALID"
    case permissionNotDetermined = "CONTACTS_PERMISSION_NOT_DETERMINED"
    case permissionDenied = "CONTACTS_PERMISSION_DENIED"
    case permissionRestricted = "CONTACTS_PERMISSION_RESTRICTED"
    case permissionUnknown = "CONTACTS_PERMISSION_UNKNOWN"
    case targetNotAccessible = "CONTACTS_TARGET_NOT_ACCESSIBLE"
    case targetStale = "CONTACTS_TARGET_STALE"
    case updateUnsupported = "CONTACTS_UPDATE_UNSUPPORTED"
    case saveFailed = "CONTACTS_SAVE_FAILED"
}


private struct ContactsCreateArguments: Sendable {
    let desired: ContactsDesiredContact

    init?(_ payload: [String: JSONValue]) {
        guard let desired = ContactsMutationArgumentsParser.desired(payload, targetKeys: []) else { return nil }
        self.desired = desired
    }
}


private struct ContactsUpdateArguments: Sendable {
    let contactID: String
    let expectedRevision: String
    let desired: ContactsDesiredContact

    init?(_ payload: [String: JSONValue]) {
        guard let desired = ContactsMutationArgumentsParser.desired(
            payload,
            targetKeys: ["contact_id", "expected_revision"]
        ),
        let contactID = ContactsMutationArgumentsParser.clean(payload["contact_id"]?.stringValue),
        contactID.count <= 512,
        let revision = ContactsMutationArgumentsParser.clean(payload["expected_revision"]?.stringValue)?.lowercased(),
        revision.count == 64,
        revision.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.contactID = contactID
        self.expectedRevision = revision
        self.desired = desired
    }
}


private enum ContactsMutationArgumentsParser {
    static let desiredKeys: Set<String> = [
        "given_name", "family_name", "organization_name", "phone_numbers", "email_addresses"
    ]

    static func desired(_ payload: [String: JSONValue], targetKeys: Set<String>) -> ContactsDesiredContact? {
        guard Set(payload.keys) == desiredKeys.union(targetKeys),
              let given = cleanAllowEmpty(payload["given_name"]?.stringValue), given.count <= 80,
              let family = cleanAllowEmpty(payload["family_name"]?.stringValue), family.count <= 80,
              let organization = cleanAllowEmpty(payload["organization_name"]?.stringValue), organization.count <= 160,
              let phones = methods(payload["phone_numbers"], kind: .phone),
              let emails = methods(payload["email_addresses"], kind: .email) else { return nil }
        let result = ContactsDesiredContact(
            givenName: given,
            familyName: family,
            organizationName: organization,
            phoneNumbers: phones,
            emailAddresses: emails
        )
        return result.hasMeaningfulContent ? result : nil
    }

    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func cleanAllowEmpty(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func methods(_ value: JSONValue?, kind: ContactsFieldCodec.MethodKind) -> [ContactsLabeledValueSnapshot]? {
        guard let rows = value?.arrayValue, rows.count <= 3 else { return nil }
        let allowed: Set<String> = kind == .phone ? ["mobile", "home", "work", "other"] : ["home", "work", "other"]
        let maxLength = kind == .phone ? 64 : 254
        var result: [ContactsLabeledValueSnapshot] = []
        var seen = Set<String>()
        for row in rows {
            guard let object = row.objectValue,
                  Set(object.keys) == ["label", "value"],
                  let label = object["label"]?.stringValue,
                  allowed.contains(label),
                  let raw = object["value"]?.stringValue else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= maxLength else { return nil }
            if kind == .email {
                guard let at = text.firstIndex(of: "@"), at != text.startIndex,
                      text.index(after: at) != text.endIndex else { return nil }
            }
            let identity = "\(label)|\(kind == .email ? text.lowercased() : text)"
            guard seen.insert(identity).inserted else { return nil }
            result.append(.init(label: label, value: text))
        }
        return result
    }
}


private enum ContactsMutationResultBuilder {
    static func create(
        _ readback: ContactsMutationReadback,
        authorization: ContactsAuthorizationScope
    ) -> DeviceExecutionResult {
        let snapshot = readback.snapshot
        let createdID = readback.createdContactID ?? snapshot.requestedContactID
        let common = commonObject(snapshot, authorization: authorization)
        var output = common
        output["operation"] = .string("create")
        output["created_contact_id"] = .string(createdID)
        output["canonicalized"] = .bool(snapshot.contactID != createdID)
        output["created_id_linked_into_result"] = .bool(snapshot.requestedIDLinkedIntoResult)
        output["applied"] = .bool(true)
        return .success(output, nativeCorrelationID: createdID)
    }

    static func update(
        _ readback: ContactsMutationReadback,
        authorization: ContactsAuthorizationScope,
        requestedContactID: String
    ) -> DeviceExecutionResult {
        var output = commonObject(readback.snapshot, authorization: authorization)
        output["operation"] = .string("update")
        output["requested_contact_id"] = .string(requestedContactID)
        output["applied"] = .bool(readback.applied)
        return .success(output, nativeCorrelationID: readback.snapshot.contactID)
    }

    static func commonObject(
        _ snapshot: ContactsManagedSnapshot,
        authorization: ContactsAuthorizationScope
    ) -> [String: JSONValue] {
        [
            "authorization_scope": .string(authorization.rawValue),
            "contact_id": .string(snapshot.contactID),
            "contact_type": .string(snapshot.contactType),
            "display_name": .string(snapshot.displayName),
            "given_name": .string(snapshot.desired.givenName),
            "family_name": .string(snapshot.desired.familyName),
            "organization_name": .string(snapshot.desired.organizationName),
            "phone_numbers": .array(snapshot.desired.phoneNumbers.map { .object(["label": .string($0.label), "value": .string($0.value)]) }),
            "email_addresses": .array(snapshot.desired.emailAddresses.map { .object(["label": .string($0.label), "value": .string($0.value)]) }),
            "revision": snapshot.revision.map(JSONValue.string) ?? .null,
            "update_eligible": .bool(snapshot.updateEligible),
            "update_ineligible_reason": snapshot.updateIneligibleReason.map(JSONValue.string) ?? .null,
            "verified": .bool(true),
        ]
    }
}


actor ContactsCreateExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "contacts.create"

    private let client: any ContactsManagementClient
    private let recoveryStore: ContactsCreateRecoveryStore

    init(
        client: any ContactsManagementClient = SystemContactsManagementClient(),
        recoveryStore: ContactsCreateRecoveryStore = .shared
    ) {
        self.client = client
        self.recoveryStore = recoveryStore
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard ContactsCreateArguments(dispatch.payload) != nil else {
            return Self.failure(.invalid, "联系人创建参数无效。")
        }
        let status = await client.authorizationStatus()
        guard status == .authorized || status == .limited else {
            return Self.permissionFailure(status)
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = ContactsCreateArguments(dispatch.payload) else {
            return Self.failure(.invalid, "联系人创建参数无效。")
        }
        let authorization = await client.authorizationStatus()
        guard authorization == .authorized || authorization == .limited else {
            return Self.permissionFailure(authorization)
        }
        let desiredDigest = ContactsRevisionCodec.desiredDigest(arguments.desired)

        if let existing = try await recoveryStore.record(for: dispatch.attemptID) {
            guard existing.desiredDigest == desiredDigest else {
                throw ContactsMutationClientError.ambiguousReadback("同一联系人创建 Attempt 的恢复内容发生冲突。")
            }
            if let readback = try await client.readCreatedContact(
                id: existing.contactID,
                desired: arguments.desired
            ) {
                return ContactsMutationResultBuilder.create(readback, authorization: authorization)
            }
            throw ContactsMutationClientError.ambiguousReadback("上一次联系人创建结果仍无法确认；不会自动再次创建。")
        }

        let contactID = try await client.prepareCreate(
            attemptID: dispatch.attemptID,
            desired: arguments.desired
        )
        try await recoveryStore.prepare(
            attemptID: dispatch.attemptID,
            contactID: contactID,
            desiredDigest: desiredDigest
        )
        do {
            let readback = try await client.commitPreparedCreate(
                attemptID: dispatch.attemptID,
                expectedContactID: contactID,
                desired: arguments.desired
            )
            return ContactsMutationResultBuilder.create(readback, authorization: authorization)
        } catch let error as ContactsMutationClientError {
            switch error {
            case .nativeSaveFailed:
                throw error
            case .targetNotAccessible:
                return Self.failure(.targetNotAccessible, error.localizedDescription)
            case .targetStale:
                return Self.failure(.targetStale, error.localizedDescription)
            case .updateUnsupported:
                return Self.failure(.updateUnsupported, error.localizedDescription)
            default:
                throw error
            }
        }
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = ContactsCreateArguments(dispatch.payload) else {
            return .stillUnknown("联系人创建已越过副作用边界，但没有足够的精确恢复标识。")
        }
        let record: ContactsCreateRecoveryRecord?
        do {
            record = try await recoveryStore.record(for: dispatch.attemptID)
        } catch {
            return .stillUnknown("联系人创建恢复记录无法读取；不会自动再次创建。")
        }
        guard let record,
              record.desiredDigest == ContactsRevisionCodec.desiredDigest(arguments.desired)
        else {
            return .stillUnknown("联系人创建已越过副作用边界，但没有足够的精确恢复标识。")
        }
        let authorization = await client.authorizationStatus()
        guard authorization == .authorized || authorization == .limited else {
            return .stillUnknown("联系人权限变化，无法确认之前的创建结果。")
        }
        guard let readback = try await client.readCreatedContact(
            id: record.contactID,
            desired: arguments.desired
        ) else {
            return .stillUnknown("没有精确读回已准备的联系人；不会按姓名或电话猜测，也不会自动再次创建。")
        }
        return .completed(ContactsMutationResultBuilder.create(readback, authorization: authorization))
    }

    private static func permissionFailure(_ status: ContactsAuthorizationScope) -> DeviceExecutionResult {
        switch status {
        case .notDetermined:
            return failure(.permissionNotDetermined, "请先在花卷设置中允许联系人访问。")
        case .denied:
            return failure(.permissionDenied, "联系人权限已关闭，请在系统设置中允许后再试。")
        case .restricted:
            return failure(.permissionRestricted, "这台设备限制了联系人访问。")
        case .authorized, .limited:
            return failure(.permissionUnknown, "联系人权限状态异常。")
        case .unknown:
            return failure(.permissionUnknown, "无法确认联系人权限状态。")
        }
    }

    private static func failure(_ code: ContactsMutationFailureCode, _ message: String) -> DeviceExecutionResult {
        .failure(message, output: ["error_code": .string(code.rawValue)])
    }
}


actor ContactsUpdateExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "contacts.update"

    private let client: any ContactsManagementClient

    init(client: any ContactsManagementClient = SystemContactsManagementClient()) {
        self.client = client
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard let arguments = ContactsUpdateArguments(dispatch.payload) else {
            return Self.failure(.invalid, "联系人修改参数无效。")
        }
        let status = await client.authorizationStatus()
        guard status == .authorized || status == .limited else {
            return Self.permissionFailure(status)
        }
        guard let current = try await client.managedContact(id: arguments.contactID) else {
            return Self.failure(.targetNotAccessible, "目标联系人当前不可访问，请重新查询。")
        }
        guard current.contactID == arguments.contactID,
              current.updateEligible,
              let revision = current.revision else {
            return Self.failure(.updateUnsupported, "这个联系人由多个 linked 记录组成，V1 不会猜测应该修改哪一条。")
        }
        guard revision == arguments.expectedRevision else {
            return Self.failure(.targetStale, "联系人在确认修改前已经发生变化，请重新查询。")
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = ContactsUpdateArguments(dispatch.payload) else {
            return Self.failure(.invalid, "联系人修改参数无效。")
        }
        let authorization = await client.authorizationStatus()
        guard authorization == .authorized || authorization == .limited else {
            return Self.permissionFailure(authorization)
        }
        do {
            let readback = try await client.commitUpdate(
                id: arguments.contactID,
                expectedRevision: arguments.expectedRevision,
                desired: arguments.desired
            )
            return ContactsMutationResultBuilder.update(
                readback,
                authorization: authorization,
                requestedContactID: arguments.contactID
            )
        } catch let error as ContactsMutationClientError {
            switch error {
            case .targetNotAccessible:
                return Self.failure(.targetNotAccessible, error.localizedDescription)
            case .targetStale:
                return Self.failure(.targetStale, error.localizedDescription)
            case .updateUnsupported:
                return Self.failure(.updateUnsupported, error.localizedDescription)
            case .nativeSaveFailed:
                throw error
            default:
                throw error
            }
        }
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        guard let arguments = ContactsUpdateArguments(dispatch.payload) else {
            return .stillUnknown("联系人修改参数无法恢复。")
        }
        let authorization = await client.authorizationStatus()
        guard authorization == .authorized || authorization == .limited else {
            return .stillUnknown("联系人权限变化，无法确认之前的修改结果。")
        }
        guard let current = try await client.managedContact(id: arguments.contactID),
              current.contactID == arguments.contactID,
              current.updateEligible else {
            return .stillUnknown("无法精确读回原联系人，不能推断修改是否发生。")
        }
        guard current.desired == arguments.desired else {
            return .stillUnknown("联系人当前状态不能证明之前的修改已完成；不会自动再次保存。")
        }
        let readback = ContactsMutationReadback(snapshot: current, applied: true, createdContactID: nil)
        return .completed(
            ContactsMutationResultBuilder.update(
                readback,
                authorization: authorization,
                requestedContactID: arguments.contactID
            )
        )
    }

    private static func permissionFailure(_ status: ContactsAuthorizationScope) -> DeviceExecutionResult {
        switch status {
        case .notDetermined:
            return failure(.permissionNotDetermined, "请先在花卷设置中允许联系人访问。")
        case .denied:
            return failure(.permissionDenied, "联系人权限已关闭，请在系统设置中允许后再试。")
        case .restricted:
            return failure(.permissionRestricted, "这台设备限制了联系人访问。")
        case .authorized, .limited:
            return failure(.permissionUnknown, "联系人权限状态异常。")
        case .unknown:
            return failure(.permissionUnknown, "无法确认联系人权限状态。")
        }
    }

    private static func failure(_ code: ContactsMutationFailureCode, _ message: String) -> DeviceExecutionResult {
        .failure(message, output: ["error_code": .string(code.rawValue)])
    }
}
