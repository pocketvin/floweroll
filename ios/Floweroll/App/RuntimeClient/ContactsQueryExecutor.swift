import Contacts
import Foundation
import Observation


enum ContactsAuthorizationScope: String, Sendable, Equatable {
    case notDetermined = "not_determined"
    case restricted
    case denied
    case authorized
    case limited
    case unknown

    static func current() -> ContactsAuthorizationScope {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .unknown
        }
    }

    var allowsQuery: Bool {
        self == .authorized || self == .limited
    }
}


struct ContactsLabeledValueSnapshot: Codable, Sendable, Equatable {
    let label: String
    let value: String
}


struct ContactsContactSnapshot: Sendable, Equatable {
    let requestedContactID: String
    let contactID: String
    let requestedIDLinkedIntoResult: Bool
    let contactType: String
    let displayName: String
    let givenName: String
    let familyName: String
    let organizationName: String?
    let phoneNumbers: [ContactsLabeledValueSnapshot]
    let emailAddresses: [ContactsLabeledValueSnapshot]
    let revision: String?
    let updateEligible: Bool
    let updateIneligibleReason: String?
    let containerResolution: String
}


protocol ContactsQueryClient: Sendable {
    func authorizationStatus() async -> ContactsAuthorizationScope
    func searchContactIDs(name: String, limit: Int) async throws -> [String]
    func exactContact(id: String) async throws -> ContactsContactSnapshot?
}


actor SystemContactsQueryClient: ContactsQueryClient {
    private let store = CNContactStore()

    func authorizationStatus() async -> ContactsAuthorizationScope {
        ContactsAuthorizationScope.current()
    }

    func searchContactIDs(name: String, limit: Int) async throws -> [String] {
        let request = CNContactFetchRequest(
            keysToFetch: [CNContactIdentifierKey as any CNKeyDescriptor]
        )
        request.predicate = CNContact.predicateForContacts(matchingName: name)
        request.unifyResults = true
        request.sortOrder = .userDefault

        var identifiers: [String] = []
        try store.enumerateContacts(with: request) { contact, stop in
            identifiers.append(contact.identifier)
            if identifiers.count >= limit {
                stop.pointee = true
            }
        }
        return identifiers
    }

    func exactContact(id: String) async throws -> ContactsContactSnapshot? {
        guard let managed = try ContactsNativeManagementReader.managedSnapshot(
            store: store,
            requestedID: id
        ) else {
            return nil
        }
        let organization = managed.desired.organizationName
        return ContactsContactSnapshot(
            requestedContactID: id,
            contactID: managed.contactID,
            requestedIDLinkedIntoResult: managed.requestedIDLinkedIntoResult,
            contactType: managed.contactType,
            displayName: managed.displayName,
            givenName: managed.desired.givenName,
            familyName: managed.desired.familyName,
            organizationName: organization.isEmpty ? nil : organization,
            phoneNumbers: managed.desired.phoneNumbers,
            emailAddresses: managed.desired.emailAddresses,
            revision: managed.revision,
            updateEligible: managed.updateEligible,
            updateIneligibleReason: managed.updateIneligibleReason,
            containerResolution: managed.containerResolution
        )
    }

    private static func keysToFetch() -> [any CNKeyDescriptor] {
        [
            CNContactIdentifierKey as any CNKeyDescriptor,
            CNContactTypeKey as any CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as any CNKeyDescriptor,
            CNContactPhoneNumbersKey as any CNKeyDescriptor,
            CNContactEmailAddressesKey as any CNKeyDescriptor,
        ]
    }

    private static func localizedLabel(_ label: String?, fallback: String) -> String {
        guard let label, !label.isEmpty else { return fallback }
        let localized = CNLabeledValue<NSString>.localizedString(forLabel: label)
        return localized.isEmpty ? fallback : localized
    }
}


private enum ContactsQueryFailureCode: String {
    case invalid = "CONTACTS_QUERY_INVALID"
    case permissionNotDetermined = "CONTACTS_PERMISSION_NOT_DETERMINED"
    case permissionDenied = "CONTACTS_PERMISSION_DENIED"
    case permissionRestricted = "CONTACTS_PERMISSION_RESTRICTED"
    case permissionUnknown = "CONTACTS_PERMISSION_UNKNOWN"
    case storeChanged = "CONTACTS_STORE_CHANGED_RETRY_SAFE"
}


private struct ContactsQueryArguments: Sendable {
    enum Mode: String, Sendable { case exactID = "exact_id", name }

    let mode: Mode
    let contactID: String?
    let nameQuery: String?
    let maxResults: Int

    init?(_ payload: [String: JSONValue]) {
        let allowed: Set<String> = ["contact_id", "name_query", "max_results"]
        guard Set(payload.keys).isSubset(of: allowed) else { return nil }

        let contactID = Self.clean(payload["contact_id"]?.stringValue)
        let nameQuery = Self.clean(payload["name_query"]?.stringValue)
        guard (contactID != nil) != (nameQuery != nil) else { return nil }

        if let contactID {
            guard contactID.count <= 512,
                  payload["name_query"] == nil,
                  payload["max_results"] == nil else { return nil }
            mode = .exactID
            self.contactID = contactID
            self.nameQuery = nil
            maxResults = 1
            return
        }

        guard let nameQuery, (2...80).contains(nameQuery.count), payload["contact_id"] == nil else {
            return nil
        }
        let maxResults: Int
        if let raw = payload["max_results"] {
            guard case let .number(number) = raw,
                  number.rounded() == number,
                  number >= 1,
                  number <= 10 else { return nil }
            maxResults = Int(number)
        } else {
            maxResults = 5
        }
        mode = .name
        self.contactID = nil
        self.nameQuery = nameQuery
        self.maxResults = maxResults
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}


actor ContactsQueryExecutor: DeviceCapabilityExecutor {
    nonisolated let capabilityID = "contacts.query"

    private let client: any ContactsQueryClient

    init(client: any ContactsQueryClient = SystemContactsQueryClient()) {
        self.client = client
    }

    func preflight(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult? {
        guard ContactsQueryArguments(dispatch.payload) != nil else {
            return Self.failure(.invalid, "联系人查询参数无效。")
        }
        let status = await client.authorizationStatus()
        guard status.allowsQuery else {
            return Self.permissionFailure(status)
        }
        return nil
    }

    func execute(_ dispatch: DeviceActionDispatch) async throws -> DeviceExecutionResult {
        guard let arguments = ContactsQueryArguments(dispatch.payload) else {
            return Self.failure(.invalid, "联系人查询参数无效。")
        }
        let initialAuthorization = await client.authorizationStatus()
        guard initialAuthorization.allowsQuery else {
            return Self.permissionFailure(initialAuthorization)
        }

        do {
            let contacts: [ContactsContactSnapshot]
            let truncated: Bool
            switch arguments.mode {
            case .exactID:
                if let contactID = arguments.contactID,
                   let exact = try await client.exactContact(id: contactID) {
                    guard exact.contactID == contactID || exact.requestedIDLinkedIntoResult else {
                        return Self.failure(.storeChanged, "联系人标识在读取期间发生了变化，请重新查询。")
                    }
                    contacts = [exact]
                } else {
                    contacts = []
                }
                truncated = false

            case .name:
                guard let nameQuery = arguments.nameQuery else {
                    return Self.failure(.invalid, "联系人查询参数无效。")
                }
                let identifiers = try await client.searchContactIDs(
                    name: nameQuery,
                    limit: arguments.maxResults + 1
                )
                truncated = identifiers.count > arguments.maxResults
                var snapshots: [ContactsContactSnapshot] = []
                var seen = Set<String>()
                for requestedID in identifiers.prefix(arguments.maxResults) {
                    guard let exact = try await client.exactContact(id: requestedID),
                          exact.contactID == requestedID || exact.requestedIDLinkedIntoResult else {
                        return Self.failure(.storeChanged, "联系人列表在读取期间发生了变化，请重新查询。")
                    }
                    if seen.insert(exact.contactID).inserted {
                        snapshots.append(exact)
                    }
                }
                contacts = snapshots
            }

            let finalAuthorization = await client.authorizationStatus()
            guard finalAuthorization == initialAuthorization else {
                if !finalAuthorization.allowsQuery {
                    return Self.permissionFailure(finalAuthorization)
                }
                return Self.failure(.storeChanged, "联系人授权范围在读取期间发生了变化，请重新查询。")
            }

            let outputContacts: [JSONValue]
            switch arguments.mode {
            case .exactID:
                outputContacts = contacts.map { .object(Self.exactObject($0)) }
            case .name:
                outputContacts = contacts.map { .object(Self.nameObject($0)) }
            }
            let emptyReason: JSONValue = contacts.isEmpty
                ? .string(initialAuthorization == .limited ? "not_accessible_or_not_found" : "no_match")
                : .null
            return .success(
                [
                    "query_mode": .string(arguments.mode.rawValue),
                    "authorization_scope": .string(initialAuthorization.rawValue),
                    "found": .bool(!contacts.isEmpty),
                    "requested_contact_id": arguments.contactID.map(JSONValue.string) ?? .null,
                    "name_query": arguments.nameQuery.map(JSONValue.string) ?? .null,
                    "contacts": .array(outputContacts),
                    "truncated": .bool(truncated),
                    "empty_reason": emptyReason,
                    "verified": .bool(true),
                ],
                nativeCorrelationID: contacts.count == 1 ? contacts[0].contactID : nil
            )
        } catch {
            return Self.failure(.storeChanged, "联系人读取没有稳定完成，请重新查询。")
        }
    }

    func reconcile(
        _ dispatch: DeviceActionDispatch,
        journalEntry: DeviceActionJournalEntry
    ) async throws -> DeviceReconciliationResult {
        .completed(try await execute(dispatch))
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

    private static func failure(
        _ code: ContactsQueryFailureCode,
        _ message: String
    ) -> DeviceExecutionResult {
        .failure(message, output: ["error_code": .string(code.rawValue)])
    }

    private static func nameObject(_ snapshot: ContactsContactSnapshot) -> [String: JSONValue] {
        [
            "contact_id": .string(snapshot.contactID),
            "contact_type": .string(snapshot.contactType),
            "display_name": .string(snapshot.displayName),
            "organization_name": snapshot.organizationName.map(JSONValue.string) ?? .null,
            "phone_hints": .array(snapshot.phoneNumbers.prefix(2).map { .string(maskPhone($0.value)) }),
            "email_hints": .array(snapshot.emailAddresses.prefix(2).map { .string(maskEmail($0.value)) }),
            "representation": .string("unified_contact"),
            "container_resolution": .string("deferred_v1"),
        ]
    }

    private static func exactObject(_ snapshot: ContactsContactSnapshot) -> [String: JSONValue] {
        let phones = Array(snapshot.phoneNumbers.prefix(3))
        let emails = Array(snapshot.emailAddresses.prefix(3))
        return [
            "requested_contact_id": .string(snapshot.requestedContactID),
            "contact_id": .string(snapshot.contactID),
            "canonicalized": .bool(snapshot.contactID != snapshot.requestedContactID),
            "requested_id_linked_into_result": .bool(snapshot.requestedIDLinkedIntoResult),
            "contact_type": .string(snapshot.contactType),
            "display_name": .string(snapshot.displayName),
            "given_name": .string(snapshot.givenName),
            "family_name": .string(snapshot.familyName),
            "organization_name": snapshot.organizationName.map(JSONValue.string) ?? .null,
            "phone_numbers": .array(phones.map { .object(["label": .string($0.label), "value": .string($0.value)]) }),
            "email_addresses": .array(emails.map { .object(["label": .string($0.label), "value": .string($0.value)]) }),
            "phone_values_truncated": .bool(snapshot.phoneNumbers.count > phones.count),
            "email_values_truncated": .bool(snapshot.emailAddresses.count > emails.count),
            "revision": snapshot.revision.map(JSONValue.string) ?? .null,
            "update_eligible": .bool(snapshot.updateEligible),
            "update_ineligible_reason": snapshot.updateIneligibleReason.map(JSONValue.string) ?? .null,
            "representation": .string("unified_contact"),
            "container_resolution": .string(snapshot.containerResolution),
        ]
    }

    private static func maskPhone(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        let suffix = String(digits.suffix(4))
        return suffix.isEmpty ? "••••" : "••••\(suffix)"
    }

    private static func maskEmail(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = value.firstIndex(of: "@") else {
            return value.first.map { "\($0)•••" } ?? "•••"
        }
        let local = value[..<at]
        let domain = value[value.index(after: at)...]
        let first = local.first.map(String.init) ?? ""
        return "\(first)•••@\(domain)"
    }
}


@MainActor
@Observable
final class ContactsPermissionModel {
    private(set) var status = ContactsAuthorizationScope.current()
    private(set) var isRequesting = false
    private(set) var errorMessage: String?

    var statusLabel: String {
        switch status {
        case .authorized: return "已允许"
        case .limited: return "部分联系人"
        case .notDetermined: return "尚未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .unknown: return "未知"
        }
    }

    var canRequestInApp: Bool { status == .notDetermined }
    var canManageLimitedAccess: Bool { status == .limited }

    func refresh() {
        status = ContactsAuthorizationScope.current()
    }

    func requestAccess() async {
        guard !isRequesting, status == .notDetermined else { return }
        isRequesting = true
        defer { isRequesting = false }
        do {
            _ = try await CNContactStore().requestAccess(for: .contacts)
            refresh()
            errorMessage = status.allowsQuery ? nil : "没有获得联系人访问权限。"
        } catch {
            refresh()
            errorMessage = "联系人授权失败：\(error.localizedDescription)"
        }
    }
}
