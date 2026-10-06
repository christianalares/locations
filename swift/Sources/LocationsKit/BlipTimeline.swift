import CoreLocation
import Contacts
import CryptoKit
import Foundation
import MapKit
import Observation
import SwiftUI
#if os(iOS)
import ContactsUI
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum BlipTimelineCoverage: String, Codable, Equatable, Sendable {
    case untracked
    case partial
    case complete
}

public enum BlipTimelineConfidence: String, Codable, Equatable, Sendable {
    case observed
    case inferred
    case uncertain
}

public enum BlipTimelineTransportMode: String, Codable, Equatable, Sendable {
    case walking
    case cycling
    case driving
    case transit
    case train
    case ferry
    case flight
    case unknown
}

public enum BlipTimelineEntryKind: String, Codable, Equatable, Sendable {
    case visit
    case journey
}

enum BlipTimelineEmojiCategory: String, CaseIterable, Identifiable {
    case recent
    case smileys
    case animals
    case food
    case activities
    case travel
    case objects
    case symbols
    case flags

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "Recently Used"
        case .smileys: "Smileys & People"
        case .animals: "Animals & Nature"
        case .food: "Food & Drink"
        case .activities: "Activities"
        case .travel: "Travel & Places"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }

    var systemName: String {
        switch self {
        case .recent: "clock.fill"
        case .smileys: "face.smiling.fill"
        case .animals: "pawprint.fill"
        case .food: "fork.knife"
        case .activities: "figure.run"
        case .travel: "car.fill"
        case .objects: "lightbulb.fill"
        case .symbols: "heart.fill"
        case .flags: "flag.fill"
        }
    }

    init?(unicodeGroup: String) {
        switch unicodeGroup {
        case "Smileys & Emotion", "People & Body": self = .smileys
        case "Animals & Nature": self = .animals
        case "Food & Drink": self = .food
        case "Activities": self = .activities
        case "Travel & Places": self = .travel
        case "Objects": self = .objects
        case "Symbols": self = .symbols
        case "Flags": self = .flags
        default: return nil
        }
    }
}

enum BlipTimelinePlaceIcon {
    struct EmojiChoice: Identifiable, Equatable {
        let emoji: String
        let title: String
        let keywords: String
        let category: BlipTimelineEmojiCategory

        init(
            emoji: String,
            title: String,
            keywords: String = "",
            category: BlipTimelineEmojiCategory = .symbols
        ) {
            self.emoji = emoji
            self.title = title
            self.keywords = keywords
            self.category = category
        }

        var id: String { emoji }
        var storedValue: String { BlipTimelinePlaceIcon.storedEmoji(emoji) }
        var searchableText: String { "\(emoji) \(title) \(keywords)".lowercased() }
    }

    struct SymbolChoice: Identifiable, Equatable {
        let symbol: String
        let title: String
        let keywords: String

        init(symbol: String, title: String, keywords: String = "") {
            self.symbol = symbol
            self.title = title
            self.keywords = keywords
        }

        var id: String { symbol }
        var searchableText: String { "\(symbol) \(title) \(keywords)".lowercased() }
    }

    private static let emojiPrefix = "emoji:"

    private static let fallbackEmojiChoices: [EmojiChoice] = [
        .init(emoji: "📍", title: "Place", keywords: "pin location"),
        .init(emoji: "🏠", title: "Home"),
        .init(emoji: "🎾", title: "Tennis or padel", keywords: "sport court racket"),
        .init(emoji: "⚽️", title: "Football", keywords: "soccer sport"),
        .init(emoji: "🏀", title: "Basketball", keywords: "sport court"),
        .init(emoji: "🏓", title: "Table tennis", keywords: "ping pong sport"),
        .init(emoji: "🏸", title: "Badminton", keywords: "racket sport"),
        .init(emoji: "⛳️", title: "Golf", keywords: "sport course"),
        .init(emoji: "🏊‍♂️", title: "Swimming", keywords: "pool sport"),
        .init(emoji: "🏋️", title: "Gym", keywords: "fitness workout training"),
        .init(emoji: "🏃‍♂️", title: "Running", keywords: "fitness track sport"),
        .init(emoji: "🚴‍♂️", title: "Cycling", keywords: "bike sport"),
        .init(emoji: "☕️", title: "Coffee", keywords: "cafe fika"),
        .init(emoji: "🍽️", title: "Food", keywords: "restaurant dinner lunch"),
        .init(emoji: "🍕", title: "Pizza", keywords: "food restaurant"),
        .init(emoji: "🍔", title: "Burger", keywords: "food restaurant"),
        .init(emoji: "🥗", title: "Healthy food", keywords: "salad lunch"),
        .init(emoji: "🍣", title: "Sushi", keywords: "food restaurant"),
        .init(emoji: "🍰", title: "Bakery", keywords: "cake dessert cafe"),
        .init(emoji: "🍺", title: "Drinks", keywords: "beer bar pub"),
        .init(emoji: "🍷", title: "Wine", keywords: "bar drinks"),
        .init(emoji: "🍸", title: "Cocktails", keywords: "bar drinks"),
        .init(emoji: "🛒", title: "Groceries", keywords: "shopping supermarket"),
        .init(emoji: "🛍️", title: "Shopping", keywords: "store mall"),
        .init(emoji: "💼", title: "Work", keywords: "office job"),
        .init(emoji: "🏢", title: "Office", keywords: "work building"),
        .init(emoji: "🏥", title: "Health", keywords: "hospital doctor clinic"),
        .init(emoji: "🩺", title: "Doctor", keywords: "health clinic"),
        .init(emoji: "💊", title: "Pharmacy", keywords: "health medicine"),
        .init(emoji: "🌳", title: "Park", keywords: "outdoors nature"),
        .init(emoji: "🏞️", title: "Nature", keywords: "outdoors park"),
        .init(emoji: "🏖️", title: "Beach", keywords: "outdoors vacation"),
        .init(emoji: "⛰️", title: "Mountain", keywords: "outdoors hiking"),
        .init(emoji: "🎭", title: "Theatre", keywords: "entertainment culture"),
        .init(emoji: "🎬", title: "Cinema", keywords: "movie entertainment"),
        .init(emoji: "🎵", title: "Music", keywords: "concert entertainment"),
        .init(emoji: "🎨", title: "Art", keywords: "museum gallery culture"),
        .init(emoji: "🎮", title: "Gaming", keywords: "entertainment arcade"),
        .init(emoji: "✈️", title: "Airport", keywords: "travel flight"),
        .init(emoji: "🚆", title: "Train", keywords: "travel station transit"),
        .init(emoji: "🚇", title: "Metro", keywords: "travel subway transit"),
        .init(emoji: "🚗", title: "Car", keywords: "travel parking driving"),
        .init(emoji: "⛴️", title: "Ferry", keywords: "travel boat"),
        .init(emoji: "🏨", title: "Hotel"),
        .init(emoji: "🏫", title: "School", keywords: "education university"),
        .init(emoji: "📚", title: "Library", keywords: "books study education"),
        .init(emoji: "💇‍♀️", title: "Hairdresser", keywords: "salon beauty"),
        .init(emoji: "💅", title: "Nails", keywords: "salon beauty"),
        .init(emoji: "🐕", title: "Dog", keywords: "pet animal"),
        .init(emoji: "🎉", title: "Party", keywords: "celebration friends"),
        .init(emoji: "❤️", title: "Favorite"),
        .init(emoji: "⭐️", title: "Special place"),
    ]

    private struct EmojiCatalog: Decodable {
        let unicodeVersion: String
        let source: String
        let emojis: [EmojiCatalogEntry]
    }

    private struct EmojiCatalogEntry: Decodable {
        let emoji: String
        let name: String
        let group: String
        let subgroup: String
    }

    /// The bundled catalog follows Unicode's CLDR keyboard ordering. The small
    /// place-focused list above is retained only as a launch-safe fallback and
    /// as extra search vocabulary for terms such as "padel" and "fika".
    static let emojiChoices: [EmojiChoice] = {
        guard let resourceURL = Bundle.module.url(
            forResource: "emoji-catalog",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: resourceURL),
        let catalog = try? JSONDecoder().decode(EmojiCatalog.self, from: data)
        else {
            return fallbackEmojiChoices
        }

        let placeMetadata = Dictionary(
            uniqueKeysWithValues: fallbackEmojiChoices.map { ($0.emoji, $0) }
        )
        return catalog.emojis.compactMap { entry in
            guard let category = BlipTimelineEmojiCategory(unicodeGroup: entry.group) else {
                return nil
            }
            let metadata = placeMetadata[entry.emoji]
            return EmojiChoice(
                emoji: entry.emoji,
                title: metadata?.title ?? entry.name,
                keywords: [entry.name, entry.group, entry.subgroup, metadata?.keywords]
                    .compactMap { $0 }
                    .joined(separator: " "),
                category: category
            )
        }
    }()

    static let symbolChoices: [SymbolChoice] = [
        .init(symbol: "mappin", title: "Pin", keywords: "place location"),
        .init(symbol: "house.fill", title: "Home"),
        .init(symbol: "fork.knife", title: "Restaurant", keywords: "food"),
        .init(symbol: "cup.and.saucer.fill", title: "Café", keywords: "coffee fika"),
        .init(symbol: "cart.fill", title: "Groceries", keywords: "shopping"),
        .init(symbol: "basket.fill", title: "Store", keywords: "shopping"),
        .init(symbol: "fuelpump.fill", title: "Fuel", keywords: "gas charging"),
        .init(symbol: "cross.case.fill", title: "Health", keywords: "hospital doctor"),
        .init(symbol: "bed.double.fill", title: "Hotel", keywords: "sleep"),
        .init(symbol: "figure.run", title: "Fitness", keywords: "gym sport"),
        .init(symbol: "leaf.fill", title: "Outdoors", keywords: "nature park"),
        .init(symbol: "building.2.fill", title: "Building", keywords: "office"),
        .init(symbol: "building.columns.fill", title: "Institution", keywords: "school museum"),
        .init(symbol: "car.fill", title: "Car", keywords: "parking driving"),
        .init(symbol: "tram.fill", title: "Transit", keywords: "train travel"),
        .init(symbol: "theatermasks.fill", title: "Entertainment", keywords: "theatre"),
        .init(symbol: "star.fill", title: "Favorite", keywords: "special"),
    ]

    static var choices: [String] { symbolChoices.map(\.symbol) }

    static func storedEmoji(_ emoji: String) -> String {
        emojiPrefix + emoji
    }

    static func emoji(from storedValue: String) -> String? {
        if storedValue.hasPrefix(emojiPrefix) {
            let value = String(storedValue.dropFirst(emojiPrefix.count))
            return customEmoji(from: value)
        }
        // Be liberal when reading an early/manual value that stored the emoji
        // directly, while new writes remain explicitly namespaced.
        let value = customEmoji(from: storedValue)
        return value == storedValue ? value : nil
    }

    static func customEmoji(from input: String) -> String? {
        input.first(where: isEmoji).map(String.init)
    }

    static func title(for storedValue: String) -> String {
        if let emoji = emoji(from: storedValue) {
            return emojiChoices.first(where: { $0.emoji == emoji })?.title ?? "Emoji"
        }
        return symbolChoices.first(where: { $0.symbol == storedValue })?.title ?? "Icon"
    }

    static func filteredEmojiChoices(
        query: String,
        category: BlipTimelineEmojiCategory,
        recentEmojis: [String] = []
    ) -> [EmojiChoice] {
        let normalizedQuery = normalizedSearchText(query)
        if !normalizedQuery.isEmpty {
            var matches = emojiChoices.enumerated().filter {
                normalizedSearchText($0.element.searchableText).contains(normalizedQuery)
            }.sorted { lhs, rhs in
                let lhsRank = emojiSearchRank(
                    choice: lhs.element,
                    normalizedQuery: normalizedQuery
                )
                let rhsRank = emojiSearchRank(
                    choice: rhs.element,
                    normalizedQuery: normalizedQuery
                )
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }.map(\.element)
            if let emoji = customEmoji(from: query),
               !matches.contains(where: { $0.emoji == emoji }) {
                let knownChoice = emojiChoices.first(where: { $0.emoji == emoji })
                matches.insert(
                    knownChoice ?? EmojiChoice(
                        emoji: emoji,
                        title: "Use this emoji",
                        category: .symbols
                    ),
                    at: 0
                )
            }
            return matches
        }

        if category == .recent {
            let choicesByEmoji = Dictionary(
                uniqueKeysWithValues: emojiChoices.map { ($0.emoji, $0) }
            )
            return recentEmojis.compactMap { emoji in
                choicesByEmoji[emoji] ?? EmojiChoice(
                    emoji: emoji,
                    title: "Recently used",
                    category: .symbols
                )
            }
        }
        return emojiChoices.filter { $0.category == category }
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .autoupdatingCurrent
        )
    }

    private static func emojiSearchRank(
        choice: EmojiChoice,
        normalizedQuery: String
    ) -> Int {
        let title = normalizedSearchText(choice.title)
        if title == normalizedQuery || title.hasPrefix("flag: \(normalizedQuery)") {
            return 0
        }
        if title.hasPrefix(normalizedQuery) {
            return 1
        }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: {
            $0.hasPrefix(normalizedQuery)
        }) {
            return 2
        }
        return 3
    }

    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        return scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.count > 1 && scalars.contains { $0.properties.isEmoji })
    }

    static func symbol(for category: MKPointOfInterestCategory?) -> String {
        guard let category else { return "mappin" }
        if category == .restaurant { return "fork.knife" }
        if category == .cafe || category == .bakery { return "cup.and.saucer.fill" }
        if category == .foodMarket { return "cart.fill" }
        if category == .store { return "basket.fill" }
        if category == .gasStation || category == .evCharger { return "fuelpump.fill" }
        if category == .hospital || category == .pharmacy { return "cross.case.fill" }
        if category == .hotel { return "bed.double.fill" }
        if category == .fitnessCenter || category == .stadium { return "figure.run" }
        if category == .park || category == .nationalPark { return "leaf.fill" }
        if category == .school || category == .university || category == .library {
            return "building.columns.fill"
        }
        if category == .parking || category == .carRental { return "car.fill" }
        if category == .publicTransport || category == .airport { return "tram.fill" }
        if category == .movieTheater || category == .theater { return "theatermasks.fill" }
        if category == .bank || category == .atm { return "building.2.fill" }
        return "mappin"
    }
}

struct BlipTimelineMarkerGlyph: View {
    let systemName: String
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let emoji = BlipTimelinePlaceIcon.emoji(from: systemName) {
                Text(emoji)
                    // Emoji fonts have a taller line box than similarly sized
                    // SF Symbols. Keep their intrinsic line height so flags and
                    // multi-scalar glyphs do not get clipped by compact Timeline
                    // markers, then center that glyph in a little breathing room.
                    .font(.system(size: size * 1.05))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(width: size * 1.25, height: size * 1.25)
            } else {
                Image(systemName: systemName)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    .fontWeight(.semibold)
                    .frame(width: size, height: size)
            }
        }
    }
}

public struct BlipTimelineCoordinate: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A privacy-minimal snapshot of a person explicitly associated with a saved
/// place. `id`, `displayName`, and privacy-safe contact match tokens may travel
/// through Blip Cloud. The Contacts identifier and photo remain device-local.
public struct BlipTimelineResidentReference: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, contactIdentifier, displayName, contactMatchTokens
    }

    public let id: String
    public let contactIdentifier: String
    public let displayName: String
    public let contactMatchTokens: [String]

    public init(
        id: String = "resident-\(UUID().uuidString.lowercased())",
        contactIdentifier: String = "",
        displayName: String,
        contactMatchTokens: [String] = []
    ) {
        self.id = id
        self.contactIdentifier = contactIdentifier
        let cleaned = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = cleaned.isEmpty ? "Unnamed contact" : cleaned
        self.contactMatchTokens = Array(Set(contactMatchTokens.filter { !$0.isEmpty })).sorted()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            contactIdentifier: try values.decodeIfPresent(
                String.self,
                forKey: .contactIdentifier
            ) ?? "",
            displayName: try values.decode(String.self, forKey: .displayName),
            contactMatchTokens: try values.decodeIfPresent(
                [String].self,
                forKey: .contactMatchTokens
            ) ?? []
        )
    }

    var initials: String {
        let words = displayName.split(whereSeparator: { $0.isWhitespace })
        let selected = words.count > 1 ? [words.first, words.last].compactMap { $0 } : words
        let value = selected.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }

    static func merging(
        _ existing: [BlipTimelineResidentReference],
        with selected: [BlipTimelineResidentReference]
    ) -> [BlipTimelineResidentReference] {
        var merged: [BlipTimelineResidentReference] = []
        for resident in existing + selected {
            guard let index = merged.firstIndex(where: {
                $0.representsSameContact(as: resident)
            }) else {
                merged.append(resident)
                continue
            }
            let stableID = merged[index].id
            merged[index] = BlipTimelineResidentReference(
                id: stableID,
                contactIdentifier: resident.contactIdentifier,
                displayName: resident.displayName,
                contactMatchTokens: Array(Set(
                    merged[index].contactMatchTokens + resident.contactMatchTokens
                ))
            )
        }
        return merged
    }

    func representsSameContact(as other: BlipTimelineResidentReference) -> Bool {
        if id == other.id { return true }
        if !contactIdentifier.isEmpty,
           !other.contactIdentifier.isEmpty,
           contactIdentifier == other.contactIdentifier { return true }
        if !Set(contactMatchTokens).isDisjoint(with: other.contactMatchTokens) { return true }
        let ownName = normalizedContactName
        return !ownName.isEmpty
            && ownName != "unnamed contact"
            && ownName == other.normalizedContactName
    }

    /// The representation uploaded to Blip Cloud deliberately excludes the
    /// device-scoped Contacts identifier while retaining stable match tokens.
    var cloudReference: BlipTimelineResidentReference {
        BlipTimelineResidentReference(
            id: id,
            displayName: displayName,
            contactMatchTokens: contactMatchTokens
        )
    }

    private var normalizedContactName: String {
        displayName
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

private struct BlipTimelineResidentAvatar: View {
    let resident: BlipTimelineResidentReference
    let size: CGFloat
    @State private var imageData: Data?

    var body: some View {
        ZStack {
            Circle().fill(fallbackColor)
#if os(iOS)
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                initials
            }
#elseif os(macOS)
            if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                initials
            }
#else
            initials
#endif
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: max(1, size * 0.055)))
        .accessibilityLabel(resident.displayName)
        .task(id: resident.id) {
            imageData = await BlipTimelineContactAvatarCache.data(for: resident)
        }
    }

    private var initials: some View {
        Text(resident.initials)
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.7)
    }

    private var fallbackColor: Color {
        let palette: [Color] = [
            .indigo, .teal, .purple, .blue, .pink, .orange,
        ]
        let value = resident.id.unicodeScalars.reduce(0) {
            (($0 &* 31) &+ Int($1.value)) & 0x7fff_ffff
        }
        return palette[value % palette.count]
    }
}

private struct BlipTimelineCompactResidentMarker: View {
    let residents: [BlipTimelineResidentReference]
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let resident = residents.first, residents.count == 1 {
                BlipTimelineResidentAvatar(resident: resident, size: size)
            } else {
                HStack(spacing: -size * 0.48) {
                    ForEach(Array(residents.prefix(2))) { resident in
                        BlipTimelineResidentAvatar(resident: resident, size: size * 0.72)
                    }
                }
                .frame(width: size, height: size)
            }

            if residents.count > 2 {
                Text("+\(residents.count - 2)")
                    .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: size * 0.46, minHeight: size * 0.46)
                    .background(BlipColor.orange, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(residents.map(\.displayName).joined(separator: ", "))
    }
}

enum BlipTimelineContactLinkStore {
    private static let defaultsKey = "blip.timeline.residentContactLinks.v1"
    private static let queue = DispatchQueue(label: "com.hiddenvillage.blip.timeline-contact-links")

    static func identifier(for residentID: String) -> String? {
        queue.sync {
            (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[residentID]
        }
    }

    static func remember(contactIdentifier: String, for residentID: String) {
        guard !contactIdentifier.isEmpty, !residentID.isEmpty else { return }
        queue.sync {
            var links = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]
                ?? [:]
            links[residentID] = contactIdentifier
            UserDefaults.standard.set(links, forKey: defaultsKey)
        }
    }

    static func remember(_ residents: [BlipTimelineResidentReference]) {
        for resident in residents where !resident.contactIdentifier.isEmpty {
            remember(contactIdentifier: resident.contactIdentifier, for: resident.id)
        }
    }
}

private enum BlipTimelineContactMatcher {
    static func matchTokens(for contact: CNContact) -> [String] {
        let emails = contact.emailAddresses.compactMap { labeled -> String? in
            let address = String(labeled.value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return address.isEmpty ? nil : "email:\(address)"
        }
        let phones = contact.phoneNumbers.compactMap { labeled -> String? in
            let digits = labeled.value.stringValue.filter(\.isNumber)
            return digits.isEmpty ? nil : "phone:\(digits)"
        }
        return Array(Set((emails + phones).map(hash))).sorted()
    }

    static func contact(
        matching resident: BlipTimelineResidentReference,
        in store: CNContactStore
    ) -> CNContact? {
        let keys = contactKeys
        let candidateIdentifiers = [
            BlipTimelineContactLinkStore.identifier(for: resident.id),
            resident.contactIdentifier.isEmpty ? nil : resident.contactIdentifier,
        ].compactMap { $0 }

        for identifier in Array(Set(candidateIdentifiers)) {
            guard let contact = try? store.unifiedContact(
                withIdentifier: identifier,
                keysToFetch: keys
            ) else { continue }
            if resident.contactMatchTokens.isEmpty
                || !Set(matchTokens(for: contact)).isDisjoint(
                    with: resident.contactMatchTokens
                ) {
                return contact
            }
        }

        let request = CNContactFetchRequest(keysToFetch: keys)
        var result: CNContact?
        var nameMatch: CNContact?
        var nameIsAmbiguous = false
        let residentName = normalizedName(resident.displayName)
        try? store.enumerateContacts(with: request) { contact, stop in
            if !resident.contactMatchTokens.isEmpty,
               !Set(matchTokens(for: contact)).isDisjoint(
                   with: resident.contactMatchTokens
               ) {
                result = contact
                stop.pointee = true
                return
            }
            let displayName = CNContactFormatter.string(from: contact, style: .fullName)
                ?? contact.organizationName
            guard !residentName.isEmpty,
                  normalizedName(displayName) == residentName else { return }
            if nameMatch == nil {
                nameMatch = contact
            } else {
                nameIsAmbiguous = true
            }
        }
        return result ?? (nameIsAmbiguous ? nil : nameMatch)
    }

    static var contactKeys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    }
}

private enum BlipTimelineContactAvatarCache {
    // NSCache is thread-safe; Swift cannot express that Objective-C guarantee.
    private nonisolated(unsafe) static let memory = NSCache<NSString, NSData>()

    static func store(_ data: Data, for residentID: String) {
        memory.setObject(data as NSData, forKey: residentID as NSString)
        guard let fileURL = fileURL(for: residentID) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
#if os(iOS)
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
#else
            try data.write(to: fileURL, options: .atomic)
#endif
        } catch {
            // Initials remain a complete fallback if a local photo cannot be cached.
        }
    }

    static func data(for resident: BlipTimelineResidentReference) async -> Data? {
        await Task.detached(priority: .utility) {
            if let cached = memory.object(forKey: resident.id as NSString) {
                return cached as Data
            }
            if let fileURL = fileURL(for: resident.id),
               let cached = try? Data(contentsOf: fileURL) {
                memory.setObject(cached as NSData, forKey: resident.id as NSString)
                return cached
            }
            let status = CNContactStore.authorizationStatus(for: .contacts)
#if os(iOS)
            guard status == .authorized || status == .limited else { return nil }
#else
            guard status == .authorized else { return nil }
#endif
            guard let contact = BlipTimelineContactMatcher.contact(
                matching: resident,
                in: CNContactStore()
            ) else { return nil }
            BlipTimelineContactLinkStore.remember(
                contactIdentifier: contact.identifier,
                for: resident.id
            )
            guard let data = contact.thumbnailImageData else { return nil }
            store(data, for: resident.id)
            return data
        }.value
    }

    private static func fileURL(for residentID: String) -> URL? {
        let allowed = residentID.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
        let fileName = String(String.UnicodeScalarView(allowed))
        guard !fileName.isEmpty else { return nil }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        return root?
            .appendingPathComponent("Locations", isDirectory: true)
            .appendingPathComponent("Timeline", isDirectory: true)
            .appendingPathComponent("ContactAvatars", isDirectory: true)
            .appendingPathComponent("\(fileName).image", isDirectory: false)
    }
}

#if os(iOS)
private struct BlipTimelineContactPickerPresenter: UIViewControllerRepresentable {
    @Binding var residents: [BlipTimelineResidentReference]
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIViewController {
        let presenter = UIViewController()
        presenter.view.backgroundColor = .clear
        return presenter
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {
        context.coordinator.parent = self
        guard isPresented else { return }
        context.coordinator.presentPicker(from: uiViewController)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency CNContactPickerDelegate,
        UIAdaptivePresentationControllerDelegate {
        var parent: BlipTimelineContactPickerPresenter
        private weak var picker: CNContactPickerViewController?
        private var isPresenting = false

        init(parent: BlipTimelineContactPickerPresenter) {
            self.parent = parent
        }

        func presentPicker(from presenter: UIViewController) {
            guard !isPresenting, picker == nil,
                  presenter.presentedViewController == nil else { return }

            isPresenting = true
            let picker = CNContactPickerViewController()
            picker.delegate = self
            picker.displayedPropertyKeys = [
                CNContactThumbnailImageDataKey,
                CNContactEmailAddressesKey,
                CNContactPhoneNumbersKey,
            ]
            self.picker = picker

            // This representable is already mounted inside the checkpoint editor.
            // Presenting from it keeps the native picker's automatic dismissal
            // isolated from the SwiftUI sheet that owns the editor itself.
            presenter.present(picker, animated: true) { [weak self, weak picker] in
                guard let self, let picker else { return }
                picker.presentationController?.delegate = self
            }
        }

        func contactPicker(
            _ picker: CNContactPickerViewController,
            didSelect contacts: [CNContact]
        ) {
            let selections = contacts.map { contact -> (BlipTimelineResidentReference, Data?) in
                let name = CNContactFormatter.string(from: contact, style: .fullName)
                    ?? contact.organizationName
                let resident = BlipTimelineResidentReference(
                    contactIdentifier: contact.identifier,
                    displayName: name,
                    contactMatchTokens: BlipTimelineContactMatcher.matchTokens(for: contact)
                )
                return (resident, contact.thumbnailImageData)
            }
            let merged = BlipTimelineResidentReference.merging(
                parent.residents,
                with: selections.map(\.0)
            )
            for (selection, thumbnail) in selections {
                guard let resident = merged.first(where: {
                          $0.representsSameContact(as: selection)
                      }) else { continue }
                BlipTimelineContactLinkStore.remember(
                    contactIdentifier: selection.contactIdentifier,
                    for: resident.id
                )
                if let thumbnail {
                    BlipTimelineContactAvatarCache.store(thumbnail, for: resident.id)
                }
            }
            parent.residents = merged
            finishPresentation()
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            finishPresentation()
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finishPresentation()
        }

        private func finishPresentation() {
            picker = nil
            isPresenting = false
            parent.isPresented = false
        }
    }
}
#endif

enum BlipTimelineMapFocus {
    static func region(for entry: BlipTimelineEntry) -> MKCoordinateRegion? {
        var coordinates = entry.route
        if coordinates.isEmpty, let coordinate = entry.coordinate {
            coordinates = [coordinate]
        }
        guard !coordinates.isEmpty else { return nil }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minimumLatitude = latitudes.min(),
              let maximumLatitude = latitudes.max(),
              let minimumLongitude = longitudes.min(),
              let maximumLongitude = longitudes.max() else { return nil }

        let minimumSpan = entry.kind == .visit ? 0.009 : 0.006
        let latitudeDelta = min(160, max(minimumSpan, (maximumLatitude - minimumLatitude) * 2))
        let longitudeDelta = min(340, max(minimumSpan, (maximumLongitude - minimumLongitude) * 1.6))
        let centerLatitude = ((minimumLatitude + maximumLatitude) / 2) - latitudeDelta * 0.15

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: max(-85, min(85, centerLatitude)),
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }

    static func region(for day: BlipTimelineDay) -> MKCoordinateRegion? {
        let coordinates = day.entries.flatMap { entry in
            if !entry.route.isEmpty {
                return entry.route
            }
            return entry.displayCoordinate.map { [$0] } ?? []
        }
        guard !coordinates.isEmpty else { return nil }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minimumLatitude = latitudes.min(),
              let maximumLatitude = latitudes.max(),
              let minimumLongitude = longitudes.min(),
              let maximumLongitude = longitudes.max() else { return nil }

        // A single checkpoint should still return to a useful day overview.
        // MapKit's automatic framing otherwise zooms tightly around that pin.
        let latitudeDelta = min(
            160,
            max(0.04, (maximumLatitude - minimumLatitude) * 2)
        )
        let longitudeDelta = min(
            340,
            max(0.04, (maximumLongitude - minimumLongitude) * 1.6)
        )
        let centerLatitude = ((minimumLatitude + maximumLatitude) / 2) - latitudeDelta * 0.15

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: max(-85, min(85, centerLatitude)),
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }
}

enum BlipTimelineTimeFormatter {
    static func string(
        from date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var style = Date.FormatStyle()
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
            .locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}

public struct BlipTimelineEntry: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, subtitle, startDate, endDate, coordinate, route
        case distanceMeters, transportMode, confidence, isHome
        case placeID, placeCoordinate, mapItemIdentifier, placeCategory, placeIcon
        case residentContacts
    }
    public let id: String
    public let kind: BlipTimelineEntryKind
    public let title: String
    public let subtitle: String?
    public let startDate: Date
    public let endDate: Date?
    public let coordinate: BlipTimelineCoordinate?
    public let route: [BlipTimelineCoordinate]
    public let distanceMeters: Double?
    public let transportMode: BlipTimelineTransportMode?
    public let confidence: BlipTimelineConfidence
    public let isHome: Bool
    public let placeID: String?
    public let placeCoordinate: BlipTimelineCoordinate?
    public let mapItemIdentifier: String?
    public let placeCategory: String?
    public let placeIcon: String?
    public let residentContacts: [BlipTimelineResidentReference]

    public init(
        id: String,
        kind: BlipTimelineEntryKind,
        title: String,
        subtitle: String? = nil,
        startDate: Date,
        endDate: Date? = nil,
        coordinate: BlipTimelineCoordinate? = nil,
        route: [BlipTimelineCoordinate] = [],
        distanceMeters: Double? = nil,
        transportMode: BlipTimelineTransportMode? = nil,
        confidence: BlipTimelineConfidence = .observed,
        isHome: Bool = false,
        placeID: String? = nil,
        placeCoordinate: BlipTimelineCoordinate? = nil,
        mapItemIdentifier: String? = nil,
        placeCategory: String? = nil,
        placeIcon: String? = nil,
        residentContacts: [BlipTimelineResidentReference] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.startDate = startDate
        self.endDate = endDate
        self.coordinate = coordinate
        self.route = route
        self.distanceMeters = distanceMeters
        self.transportMode = transportMode
        self.confidence = confidence
        self.isHome = isHome
        self.placeID = placeID
        self.placeCoordinate = placeCoordinate
        self.mapItemIdentifier = mapItemIdentifier
        self.placeCategory = placeCategory
        self.placeIcon = placeIcon
        self.residentContacts = residentContacts
    }

    public var duration: TimeInterval? {
        endDate.map { max(0, $0.timeIntervalSince(startDate)) }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(BlipTimelineEntryKind.self, forKey: .kind)
        title = try values.decode(String.self, forKey: .title)
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
        startDate = try values.decode(Date.self, forKey: .startDate)
        endDate = try values.decodeIfPresent(Date.self, forKey: .endDate)
        coordinate = try values.decodeIfPresent(BlipTimelineCoordinate.self, forKey: .coordinate)
        route = try values.decodeIfPresent([BlipTimelineCoordinate].self, forKey: .route) ?? []
        distanceMeters = try values.decodeIfPresent(Double.self, forKey: .distanceMeters)
        transportMode = try values.decodeIfPresent(
            BlipTimelineTransportMode.self,
            forKey: .transportMode
        )
        confidence = try values.decodeIfPresent(
            BlipTimelineConfidence.self,
            forKey: .confidence
        ) ?? .observed
        isHome = try values.decodeIfPresent(Bool.self, forKey: .isHome) ?? false
        placeID = try values.decodeIfPresent(String.self, forKey: .placeID)
        placeCoordinate = try values.decodeIfPresent(
            BlipTimelineCoordinate.self,
            forKey: .placeCoordinate
        )
        mapItemIdentifier = try values.decodeIfPresent(String.self, forKey: .mapItemIdentifier)
        placeCategory = try values.decodeIfPresent(String.self, forKey: .placeCategory)
        placeIcon = try values.decodeIfPresent(String.self, forKey: .placeIcon)
        residentContacts = try values.decodeIfPresent(
            [BlipTimelineResidentReference].self,
            forKey: .residentContacts
        ) ?? []
    }

    public var placeSystemImage: String {
        placeIcon ?? (isHome ? "house.fill" : "mappin")
    }

    public var displayCoordinate: BlipTimelineCoordinate? {
        placeCoordinate ?? coordinate
    }
}

public struct BlipTimelineActivityMetrics: Codable, Equatable, Sendable {
    public let distanceMeters: Double
    public let movingDuration: TimeInterval
    public let awayFromHomeDuration: TimeInterval
    public let meaningfulPlaceCount: Int

    public init(
        distanceMeters: Double,
        movingDuration: TimeInterval,
        awayFromHomeDuration: TimeInterval,
        meaningfulPlaceCount: Int
    ) {
        self.distanceMeters = max(0, distanceMeters)
        self.movingDuration = max(0, movingDuration)
        self.awayFromHomeDuration = max(0, awayFromHomeDuration)
        self.meaningfulPlaceCount = max(0, meaningfulPlaceCount)
    }
}

extension BlipTimelineActivityMetrics {
    static func derived(from entries: [BlipTimelineEntry]) -> Self {
        let journeys = entries.filter { $0.kind == .journey }
        let visits = entries.filter { $0.kind == .visit }
        let distance = journeys.compactMap(\.distanceMeters).reduce(0, +)
        let movement = journeys.compactMap(\.duration).reduce(0, +)
        let awayVisits = visits.filter { !$0.isHome }.compactMap(\.duration).reduce(0, +)
        return Self(
            distanceMeters: distance,
            movingDuration: movement,
            awayFromHomeDuration: min(86_400, movement + awayVisits),
            meaningfulPlaceCount: visits.filter {
                !$0.isHome && ($0.duration ?? 0) >= 8 * 60
            }.count
        )
    }
}

public enum BlipTimelineHeatLevel: String, Codable, Equatable, Sendable {
    case cold
    case cool
    case warm
    case hot
    case intense
}

public struct BlipTimelineHeatScore: Codable, Equatable, Sendable {
    public let value: Double
    public let level: BlipTimelineHeatLevel

    public init(value: Double, level: BlipTimelineHeatLevel) {
        self.value = min(max(value, 0), 1)
        self.level = level
    }
}

public enum BlipTimelineHeatCalculator {
    /// Scores meaningful movement rather than GPS sample count. Every component
    /// saturates, so an unusually long journey cannot drown out the rest of a day.
    public static func score(for metrics: BlipTimelineActivityMetrics) -> BlipTimelineHeatScore {
        let distance = saturation(metrics.distanceMeters / 1_000, scale: 12)
        let movement = saturation(metrics.movingDuration / 3_600, scale: 3)
        let away = saturation(metrics.awayFromHomeDuration / 3_600, scale: 6)
        let places = saturation(Double(metrics.meaningfulPlaceCount), scale: 3)
        let value = (distance * 0.35) + (movement * 0.25) + (away * 0.20) + (places * 0.20)

        let level: BlipTimelineHeatLevel
        switch value {
        case ..<0.12:
            level = .cold
        case ..<0.30:
            level = .cool
        case ..<0.52:
            level = .warm
        case ..<0.74:
            level = .hot
        default:
            level = .intense
        }

        return BlipTimelineHeatScore(value: value, level: level)
    }

    private static func saturation(_ value: Double, scale: Double) -> Double {
        guard value > 0, scale > 0 else { return 0 }
        return 1 - exp(-value / scale)
    }
}

public struct BlipTimelineDay: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case date, dateKey, timeZoneIdentifier, coverage, entries, metrics
        case updatedAt, sourceDeviceID
    }
    public let date: Date
    public let dateKey: String
    public let timeZoneIdentifier: String
    public let coverage: BlipTimelineCoverage
    public let entries: [BlipTimelineEntry]
    public let metrics: BlipTimelineActivityMetrics?
    public let updatedAt: Date
    public let sourceDeviceID: String

    public var id: Date { date }
    public var orderedEntries: [BlipTimelineEntry] {
        entries.sorted { lhs, rhs in
            if lhs.startDate == rhs.startDate {
                return lhs.id < rhs.id
            }
            return lhs.startDate < rhs.startDate
        }
    }
    public var heat: BlipTimelineHeatScore? {
        guard coverage != .untracked, let metrics else { return nil }
        return BlipTimelineHeatCalculator.score(for: metrics)
    }

    func entryCoversEntireDay(_ entry: BlipTimelineEntry) -> Bool {
        guard let endDate = entry.endDate else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return false }
        return entry.startDate <= interval.start && endDate >= interval.end
    }

    public init(
        date: Date,
        dateKey: String? = nil,
        timeZoneIdentifier: String,
        coverage: BlipTimelineCoverage,
        entries: [BlipTimelineEntry],
        metrics: BlipTimelineActivityMetrics?,
        updatedAt: Date = Date(),
        sourceDeviceID: String = "unknown"
    ) {
        let uniqueEntries = Self.uniqueEntries(entries)
        self.date = date
        self.dateKey = dateKey ?? Self.makeDateKey(date, timeZoneIdentifier: timeZoneIdentifier)
        self.timeZoneIdentifier = timeZoneIdentifier
        self.coverage = coverage
        self.entries = uniqueEntries
        self.metrics = uniqueEntries.count == entries.count
            ? metrics
            : metrics.map { _ in .derived(from: uniqueEntries) }
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
    }

    private static func uniqueEntries(_ entries: [BlipTimelineEntry]) -> [BlipTimelineEntry] {
        var positions: [String: Int] = [:]
        var unique: [BlipTimelineEntry] = []
        unique.reserveCapacity(entries.count)
        for entry in entries {
            if let position = positions[entry.id] {
                // A capture rebuild or older cloud payload may repeat an ID.
                // Keep the latest representation without leaving a ghost UI row.
                unique[position] = entry
            } else {
                positions[entry.id] = unique.count
                unique.append(entry)
            }
        }
        return unique
    }

    public static func makeDateKey(_ date: Date, timeZoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
        dateKey = try values.decode(String.self, forKey: .dateKey)
        if let decodedDate = try values.decodeIfPresent(Date.self, forKey: .date) {
            date = decodedDate
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .autoupdatingCurrent
            let parts = dateKey.split(separator: "-").compactMap { Int($0) }
            date = parts.count == 3
                ? calendar.date(from: DateComponents(
                    year: parts[0],
                    month: parts[1],
                    day: parts[2]
                )) ?? Date(timeIntervalSince1970: 0)
                : Date(timeIntervalSince1970: 0)
        }
        coverage = try values.decode(BlipTimelineCoverage.self, forKey: .coverage)
        let decodedEntries = try values.decode([BlipTimelineEntry].self, forKey: .entries)
        let uniqueEntries = Self.uniqueEntries(decodedEntries)
        entries = uniqueEntries
        let decodedMetrics = try values.decodeIfPresent(
            BlipTimelineActivityMetrics.self,
            forKey: .metrics
        )
        metrics = uniqueEntries.count == decodedEntries.count
            ? decodedMetrics
            : decodedMetrics.map { _ in .derived(from: uniqueEntries) }
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        sourceDeviceID = try values.decodeIfPresent(String.self, forKey: .sourceDeviceID)
            ?? "unknown"
    }
}

@MainActor
@Observable
public final class BlipTimelineStore {
    public internal(set) var days: [BlipTimelineDay]
    public var selectedDate: Date
    public internal(set) var trackingEnabled: Bool
    public internal(set) var trackingState: BlipTimelineTrackingState
    public internal(set) var backgroundCaptureStatus: BlipTimelineBackgroundCaptureStatus
    public internal(set) var isActivelySampling = false
    public internal(set) var isSyncing = false
    public internal(set) var lastSampleAt: Date?
    public internal(set) var lastSyncAt: Date?
    public internal(set) var persistenceError: String?
    public internal(set) var syncError: String?
    public internal(set) var workoutsByDateKey: [String: [BlipTimelineWorkout]] = [:]
    public internal(set) var workoutError: String?

    let calendar: Calendar
    let cloudSession: BlipCloudSession?
    let persistence: BlipTimelinePersistence
    let sourceDeviceID: String
    var ledger: BlipTimelineLedger
    @ObservationIgnored let usesDemoData: Bool
    @ObservationIgnored var automaticSyncTask: Task<Void, Never>?
    @ObservationIgnored var automaticSyncID: UUID?
    @ObservationIgnored var syncRetryDelay: TimeInterval = 15
#if os(iOS)
    @ObservationIgnored var captureController: BlipTimelineCaptureController?
    @ObservationIgnored private let workoutSource = BlipTimelineHealthWorkoutSource()
#endif

    public convenience init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.init(
            arguments: arguments,
            calendar: calendar,
            cloudSession: nil,
            persistence: .applicationSupport()
        )
    }

    public convenience init(
        syncSession: BlipCloudSession,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.init(
            arguments: arguments,
            calendar: calendar,
            cloudSession: syncSession,
            persistence: .applicationSupport()
        )
    }

    init(
        arguments: [String],
        calendar: Calendar,
        cloudSession: BlipCloudSession?,
        persistence: BlipTimelinePersistence
    ) {
        self.calendar = calendar
        self.cloudSession = cloudSession
        self.persistence = persistence
        self.sourceDeviceID = Self.loadSourceDeviceID()
        self.usesDemoData = arguments.contains("-blipDemoTimeline")
        var restored = usesDemoData ? .empty : persistence.load()
        let removedRedundantObservationCount = restored.compactRedundantObservations()
        let removedDuplicatePlaceCount = restored.canonicalizeSavedPlaces()
#if os(iOS)
        let preparedResidentCloudSync = restored.prepareResidentCloudSync()
        BlipTimelineContactLinkStore.remember(
            restored.days.flatMap(\.entries).flatMap(\.residentContacts)
                + restored.savedPlaces.flatMap(\.residentContacts)
        )
#else
        let preparedResidentCloudSync = false
#endif
        self.ledger = restored
        self.trackingEnabled = restored.trackingEnabled
        self.trackingState = restored.trackingEnabled ? .requestingPermission : .stopped
        self.backgroundCaptureStatus = restored.backgroundCaptureStatus
            ?? (restored.trackingEnabled ? .checking : .unavailable)
        self.lastSyncAt = restored.lastBackupAt
        let today = calendar.startOfDay(for: Date())
        self.selectedDate = today
        self.days = usesDemoData
            ? Self.demoDays(today: today, calendar: calendar)
            : restored.days.sorted { $0.date < $1.date }
        if usesDemoData {
            let dateKey = BlipTimelineDay.makeDateKey(
                today,
                timeZoneIdentifier: calendar.timeZone.identifier
            )
            self.workoutsByDateKey[dateKey] = Self.demoWorkouts(today: today, calendar: calendar)
        } else if removedRedundantObservationCount > 0
            || removedDuplicatePlaceCount > 0
            || preparedResidentCloudSync {
            // Persist bounded raw geometry and canonical remembered places
            // once at launch. Existing derived journey routes are retained.
            persistLedger()
        }
#if os(iOS)
        let controller = BlipTimelineCaptureController.shared
        self.captureController = controller
        controller.attach(to: self, trackingEnabled: trackingEnabled)
        cloudSession?.recoveredUpload = { [weak self] body in
            guard let self,
                  let upload = try? BlipTimelinePersistence.decoder.decode(
                    LocationsTimelineUpload.self, from: body
                  ) else { return }

            acknowledgeCloudUpload(upload)
        }
        cloudSession?.reconnectBackgroundUploads()
        cloudSession?.recoveredUploadFailure = { [weak self] error in
            guard let self else { return }

            syncError = error.localizedDescription
            syncRetryDelay = min(syncRetryDelay * 2, 300)
            scheduleAutomaticSync()
        }
#endif
    }

    public func day(containing date: Date) -> BlipTimelineDay? {
        days.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    public func selectDay(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
    }

    public func selectToday(now: Date = Date()) {
        selectedDate = calendar.startOfDay(for: now)
    }

    public func moveSelection(byDays offset: Int) {
        guard let next = calendar.date(byAdding: .day, value: offset, to: selectedDate) else { return }
        let today = calendar.startOfDay(for: Date())
        selectedDate = min(calendar.startOfDay(for: next), today)
    }

    public func workouts(
        for entry: BlipTimelineEntry,
        in day: BlipTimelineDay
    ) -> [BlipTimelineWorkout] {
        BlipTimelineWorkoutMatcher.workouts(
            for: entry,
            in: day,
            workouts: workoutsByDateKey[day.dateKey] ?? []
        )
    }

#if os(iOS)
    public func refreshWorkouts(for date: Date) async {
        guard !usesDemoData, let interval = calendar.dateInterval(of: .day, for: date) else { return }
        let dateKey = BlipTimelineDay.makeDateKey(
            interval.start,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
        do {
            workoutsByDateKey[dateKey] = try await workoutSource.workouts(in: interval)
            workoutError = nil
        } catch {
            workoutError = error.localizedDescription
        }
    }
#endif

    public func replaceDays(_ days: [BlipTimelineDay]) {
        self.days = days.sorted { $0.date < $1.date }
        ledger.days = self.days
        persistLedger()
    }

    func persistLedger(scheduleSync: Bool = true) {
        guard !usesDemoData else { return }
        ledger.days = days
        if scheduleSync {
            ledger.syncRevision += 1
        }
        do {
            try persistence.save(ledger)
            persistenceError = nil
#if os(iOS)
            if scheduleSync {
                scheduleAutomaticSync()
            }
#endif
        } catch {
            persistenceError = "Timeline could not be saved locally: \(error.localizedDescription)"
        }
    }

    private static func loadSourceDeviceID(defaults: UserDefaults = .standard) -> String {
        let key = "locations.timeline.sourceDeviceID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }

    private static func demoDays(today: Date, calendar: Calendar) -> [BlipTimelineDay] {
        let historicalDays = (1...34).compactMap { offset -> BlipTimelineDay? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let pattern = offset % 7
            let metrics: BlipTimelineActivityMetrics
            switch pattern {
            case 0:
                metrics = .init(
                    distanceMeters: 23_000,
                    movingDuration: 4.5 * 3_600,
                    awayFromHomeDuration: 11 * 3_600,
                    meaningfulPlaceCount: 6
                )
            case 1, 4:
                metrics = .init(
                    distanceMeters: 8_000,
                    movingDuration: 1.8 * 3_600,
                    awayFromHomeDuration: 7 * 3_600,
                    meaningfulPlaceCount: 3
                )
            case 2:
                metrics = .init(
                    distanceMeters: 2_200,
                    movingDuration: 42 * 60,
                    awayFromHomeDuration: 2.2 * 3_600,
                    meaningfulPlaceCount: 1
                )
            default:
                metrics = .init(
                    distanceMeters: 250,
                    movingDuration: 8 * 60,
                    awayFromHomeDuration: 0,
                    meaningfulPlaceCount: 0
                )
            }
            return BlipTimelineDay(
                date: date,
                timeZoneIdentifier: TimeZone.current.identifier,
                coverage: .complete,
                entries: [],
                metrics: metrics
            )
        }

        // Fictional preview locations around Null Island (0°, 0°).
        let home = BlipTimelineCoordinate(latitude: 0, longitude: 0)
        let cafe = BlipTimelineCoordinate(latitude: 0.002, longitude: 0.003)
        let office = BlipTimelineCoordinate(latitude: 0.008, longitude: 0.001)
        let museum = BlipTimelineCoordinate(latitude: 0.004, longitude: 0.008)

        func time(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
        }

        let entries = [
            BlipTimelineEntry(
                id: "demo-home-morning",
                kind: .visit,
                title: "Home",
                subtitle: "Morning",
                startDate: time(6, 45),
                endDate: time(8, 12),
                coordinate: home
            ),
            BlipTimelineEntry(
                id: "demo-walk-cafe",
                kind: .journey,
                title: "Walk",
                startDate: time(8, 12),
                endDate: time(8, 31),
                route: [home, .init(latitude: 0.001, longitude: 0.0015), cafe],
                distanceMeters: 1_150,
                transportMode: .walking
            ),
            BlipTimelineEntry(
                id: "demo-cafe",
                kind: .visit,
                title: "Morning coffee",
                subtitle: "Null Island village",
                startDate: time(8, 31),
                endDate: time(9, 18),
                coordinate: cafe
            ),
            BlipTimelineEntry(
                id: "demo-transit-office",
                kind: .journey,
                title: "Transit",
                startDate: time(9, 18),
                endDate: time(9, 42),
                route: [cafe, .init(latitude: 0.005, longitude: 0.002), office],
                distanceMeters: 3_400,
                transportMode: .transit,
                confidence: .inferred
            ),
            BlipTimelineEntry(
                id: "demo-office",
                kind: .visit,
                title: "Studio",
                subtitle: "Zero Meridian Lane",
                startDate: time(9, 42),
                endDate: time(12, 36),
                coordinate: office
            ),
            BlipTimelineEntry(
                id: "demo-cycle-museum",
                kind: .journey,
                title: "Cycling",
                startDate: time(12, 36),
                endDate: time(12, 58),
                route: [office, .init(latitude: 0.006, longitude: 0.004), museum],
                distanceMeters: 2_900,
                transportMode: .cycling
            ),
            BlipTimelineEntry(
                id: "demo-museum",
                kind: .visit,
                title: "Lunch by the water",
                subtitle: "Null Island waterfront",
                startDate: time(12, 58),
                endDate: time(14, 10),
                coordinate: museum
            ),
        ]

        let currentDay = BlipTimelineDay(
            date: today,
            timeZoneIdentifier: TimeZone.current.identifier,
            coverage: .partial,
            entries: entries,
            metrics: .init(
                distanceMeters: 7_450,
                movingDuration: 65 * 60,
                awayFromHomeDuration: 5.9 * 3_600,
                meaningfulPlaceCount: 3
            )
        )
        return historicalDays + [currentDay]
    }

    private static func demoWorkouts(
        today: Date,
        calendar: Calendar
    ) -> [BlipTimelineWorkout] {
        func time(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) ?? today
        }

        return [
            BlipTimelineWorkout(
                id: "demo-cycling-workout",
                title: "Cycling",
                systemImage: "figure.outdoor.cycle",
                startDate: time(12, 36),
                endDate: time(12, 58),
                totalEnergyKilocalories: 176,
                totalDistanceMeters: 2_900,
                sourceName: "Apple Watch",
                isIndoor: false
            ),
        ]
    }
}

#if os(iOS)
public struct BlipTimelineView: View {
    @Bindable private var store: BlipTimelineStore
    @Binding private var isPresented: Bool
    @Binding private var showsTimelineControls: Bool
    @Binding private var showsAppSettings: Bool
    private let appSettings: () -> AnyView
    private let showsTrackingWarning: Bool
    private let mapScope: Namespace.ID?
    private let bottomNavigationClearance: CGFloat
    private let bottomNavigationPresentationContainerChanged: (UIView?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cameraPosition = MapCameraPosition.automatic
    @State private var selectedEntryID: String?
    @State private var sheetDetent = PresentationDetent.medium
    @State private var showsCalendar = false
    @State private var editingEntryID: String?
    @State private var confirmsDeleteAll = false
    @State private var exportItem: BlipTimelineExportItem?

    public init(
        store: BlipTimelineStore,
        isPresented: Binding<Bool>,
        showsTimelineControls: Binding<Bool>,
        showsAppSettings: Binding<Bool> = .constant(false),
        appSettings: @escaping () -> AnyView = { AnyView(EmptyView()) },
        showsTrackingWarning: Bool = true,
        mapScope: Namespace.ID? = nil,
        bottomNavigationClearance: CGFloat = 0,
        bottomNavigationPresentationContainerChanged: @escaping (UIView?) -> Void = { _ in },
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.store = store
        _isPresented = isPresented
        _showsTimelineControls = showsTimelineControls
        _showsAppSettings = showsAppSettings
        self.appSettings = appSettings
        self.showsTrackingWarning = showsTrackingWarning
        self.mapScope = mapScope
        self.bottomNavigationClearance = bottomNavigationClearance
        self.bottomNavigationPresentationContainerChanged =
            bottomNavigationPresentationContainerChanged
        let opensCalendar = arguments.contains("-blipDemoTimelineCalendar")
        _sheetDetent = State(initialValue: opensCalendar ? .large : .medium)
        _showsCalendar = State(initialValue: opensCalendar)
        _editingEntryID = State(
            initialValue: arguments.contains("-blipDemoTimelineEditor")
                ? "demo-cafe"
                : nil
        )
    }

    public var body: some View {
        timelineMap
            .ignoresSafeArea()
            .background(BlipColor.background)
            .task {
                resetCameraForSelectedDay()
                await store.backfillAppleMapsMetadataForSavedPlaces()
            }
            .task(id: store.selectedDate) {
                await store.refreshWorkouts(for: store.selectedDate)
            }
            .onChange(of: store.selectedDate) { _, _ in
                resetCameraForSelectedDay()
            }
            .onChange(of: showsCalendar) { _, isShowing in
                if isShowing {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                        sheetDetent = .large
                    }
                }
            }
            .sheet(isPresented: $isPresented) {
                timelineSheet
            }
    }

    private var timelineSheet: some View {
        BlipTimelineSheet(
            store: store,
            day: selectedDay,
            showsCalendar: $showsCalendar,
            selectedEntryID: $selectedEntryID,
            sheetDetent: $sheetDetent,
            selectToday: selectToday,
            selectEntry: selectEntry,
            editEntry: { editingEntryID = $0 }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: bottomNavigationClearance)
                .allowsHitTesting(false)
        }
        .background {
            BlipTimelinePresentationContainerReader(
                containerChanged: bottomNavigationPresentationContainerChanged
            )
            .frame(width: 0, height: 0)
        }
        .presentationDetents(
            [.height(168 + bottomNavigationClearance), .medium, .large],
            selection: $sheetDetent
        )
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled()
        .sheet(item: editingEntryBinding) { entry in
            BlipTimelineEntryEditor(store: store, entry: entry)
        }
        .sheet(isPresented: $showsTimelineControls) {
            BlipTimelineControls(
                store: store,
                export: makeExport,
                deleteEverything: { confirmsDeleteAll = true }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsAppSettings) {
            appSettings()
        }
        .sheet(item: $exportItem) { item in
            BlipTimelineShareSheet(url: item.url)
        }
        .confirmationDialog(
            "Permanently delete your Timeline?",
            isPresented: $confirmsDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete Timeline Everywhere", role: .destructive) {
                Task { await store.deleteEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every local and Locations server Timeline day and turns tracking off. It can’t be undone.")
        }
    }

    private var editingEntryBinding: Binding<BlipTimelineEntry?> {
        Binding(
            get: {
                guard let editingEntryID else { return nil }
                return store.days.lazy.flatMap(\.entries).first { $0.id == editingEntryID }
            },
            set: { if $0 == nil { editingEntryID = nil } }
        )
    }

    private func makeExport() {
        do {
            exportItem = BlipTimelineExportItem(url: try store.exportTimeline())
        } catch {
            store.syncError = error.localizedDescription
        }
    }

    private var selectedDay: BlipTimelineDay? {
        store.day(containing: store.selectedDate)
    }

    private func selectToday() {
        store.selectToday()
        resetCameraForSelectedDay()
    }

    private func resetCameraForSelectedDay() {
        selectedEntryID = nil
        let updateCamera = {
            if let selectedDay, let region = BlipTimelineMapFocus.region(for: selectedDay) {
                cameraPosition = .region(region)
            } else {
                cameraPosition = .automatic
            }
        }
        if reduceMotion {
            updateCamera()
        } else {
            withAnimation(.easeOut(duration: 0.28), updateCamera)
        }
    }

    private var timelineMap: some View {
        Map(position: $cameraPosition, selection: $selectedEntryID, scope: mapScope) {
            UserAnnotation()

            if let day = selectedDay {
                ForEach(day.orderedEntries.filter { $0.kind == .journey }) { entry in
                    if entry.route.count > 1 {
                        MapPolyline(coordinates: entry.route.map(\.coordinate))
                            .stroke(
                                routeColor(for: entry.confidence),
                                style: StrokeStyle(
                                    lineWidth: 4,
                                    lineCap: .round,
                                    lineJoin: .round,
                                    dash: entry.confidence == .observed ? [] : [8, 6]
                                )
                            )
                    }
                }

                ForEach(day.orderedEntries.filter { $0.kind == .visit }) { entry in
                    if let coordinate = entry.displayCoordinate?.coordinate {
                        Annotation(entry.title, coordinate: coordinate) {
                            Button {
                                selectEntry(entry)
                            } label: {
                                if !entry.isHome, !entry.residentContacts.isEmpty {
                                    BlipTimelineCompactResidentMarker(
                                        residents: entry.residentContacts,
                                        size: 30
                                    )
                                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                                } else {
                                    BlipTimelineMarkerGlyph(
                                        systemName: entry.placeSystemImage,
                                        size: 15
                                    )
                                        .foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(
                                            selectedEntryID == entry.id
                                                ? BlipColor.orange
                                                : (
                                                    BlipTimelinePlaceIcon.emoji(
                                                        from: entry.placeSystemImage
                                                    ) == nil
                                                        ? BlipColor.success
                                                        : BlipColor.surface
                                                ),
                                            in: Circle()
                                        )
                                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                                }
                            }
                            .buttonStyle(.plain)
                            .tag(entry.id)
                        }
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            if mapScope == nil {
                MapCompass()
                MapUserLocationButton()
            }
        }
        .overlay(alignment: .topLeading) {
            if showsTrackingWarning && store.trackingState != .active {
                trackingWarningBadge
                    .padding(.leading, 16)
                    .padding(.top, 8)
            }
        }
    }

    private var trackingWarningBadge: some View {
        Label(store.trackingState.title, systemImage: trackingWarningSymbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(BlipColor.warning)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(BlipColor.surface.opacity(0.82), in: Capsule())
            .glassEffect(.regular, in: Capsule())
            .overlay(Capsule().stroke(BlipColor.warning.opacity(0.38), lineWidth: 1))
    }

    private var trackingWarningSymbol: String {
        switch store.trackingState {
        case .stopped, .denied, .unavailable:
            "location.slash"
        case .requestingPermission:
            "location.magnifyingglass"
        case .whenInUseOnly:
            "location.triangle"
        case .active:
            "location.fill.viewfinder"
        }
    }

    private func routeColor(for confidence: BlipTimelineConfidence) -> Color {
        switch confidence {
        case .observed: BlipColor.success
        case .inferred: BlipColor.device
        case .uncertain: BlipColor.warning
        }
    }

    private func selectEntry(_ entry: BlipTimelineEntry) {
        selectedEntryID = entry.id
        guard let region = BlipTimelineMapFocus.region(for: entry) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
            cameraPosition = .region(region)
        }
    }

}

/// Reports the native sheet's presentation container so the root can move its
/// existing bottom navigation above the sheet without creating a second copy.
private struct BlipTimelinePresentationContainerReader: UIViewControllerRepresentable {
    let containerChanged: (UIView?) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(containerChanged: containerChanged)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(containerChanged: containerChanged)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.report(nil)
    }

    final class Controller: UIViewController {
        private var containerChanged: (UIView?) -> Void
        private weak var reportedContainer: UIView?

        init(containerChanged: @escaping (UIView?) -> Void) {
            self.containerChanged = containerChanged
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let probe = BlipTimelinePresentationProbeView()
            probe.movedToWindow = { [weak self] in
                self?.reportContainerIfPossible()
            }
            probe.backgroundColor = .clear
            probe.isUserInteractionEnabled = false
            view = probe
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            reportContainerIfPossible()
            DispatchQueue.main.async { [weak self] in
                self?.reportContainerIfPossible()
            }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            reportContainerIfPossible()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            reportContainerIfPossible()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            report(nil)
        }

        func update(containerChanged: @escaping (UIView?) -> Void) {
            self.containerChanged = containerChanged
            reportContainerIfPossible()
        }

        func report(_ container: UIView?) {
            guard reportedContainer !== container else { return }
            reportedContainer = container
            let containerChanged = containerChanged
            DispatchQueue.main.async {
                containerChanged(container)
            }
        }

        private func reportContainerIfPossible() {
            guard let host = nativeSheetHost(),
                  let container = host.presentationController?.containerView else { return }
            report(container)
        }

        private func nativeSheetHost() -> UIViewController? {
            var candidate = parent
            while let current = candidate {
                if current.presentationController is UISheetPresentationController {
                    return current
                }
                candidate = current.parent
            }
            return nil
        }

    }
}

private final class BlipTimelinePresentationProbeView: UIView {
    var movedToWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        movedToWindow?()
    }
}

private enum BlipTimelineSheetRoute: Hashable {
    case workout(String)
    case workouts(String)
}

private enum BlipTimelineWorkoutStyle {
    static let accent = Color(red: 0.64, green: 1.0, blue: 0.0)
    static let background = Color(red: 0.09, green: 0.16, blue: 0.02)
}

private struct BlipTimelineSheet: View {
    @Bindable var store: BlipTimelineStore
    let day: BlipTimelineDay?
    @Binding var showsCalendar: Bool
    @Binding var selectedEntryID: String?
    @Binding var sheetDetent: PresentationDetent
    let selectToday: () -> Void
    let selectEntry: (BlipTimelineEntry) -> Void
    let editEntry: (String) -> Void
    @State private var navigationPath = NavigationPath()

    private var calendar: Calendar { .autoupdatingCurrent }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                if showsCalendar {
                    BlipTimelineCalendar(
                        store: store,
                        selectedDate: store.selectedDate,
                        selectDate: { date in
                            store.selectDay(date)
                            showsCalendar = false
                        }
                    )
                } else {
                    timelineContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { timelineToolbar }
            .navigationDestination(for: BlipTimelineSheetRoute.self) { route in
                workoutDestination(route)
            }
        }
        .tint(BlipColor.textPrimary)
        .onChange(of: navigationPath.count) { _, depth in
            guard depth > 0, sheetDetent != .large else { return }
            withAnimation(.easeOut(duration: 0.24)) {
                sheetDetent = .large
            }
        }
    }

    @ViewBuilder
    private func workoutDestination(_ route: BlipTimelineSheetRoute) -> some View {
        switch route {
        case let .workout(workoutID):
            if let workout = selectedDayWorkouts.first(where: { $0.id == workoutID }) {
                BlipTimelineWorkoutDetail(workout: workout)
            } else {
                ContentUnavailableView(
                    "Workout unavailable",
                    systemImage: "figure.mixed.cardio"
                )
                .toolbar(.visible, for: .navigationBar)
            }
        case let .workouts(entryID):
            if let day,
               let entry = day.orderedEntries.first(where: { $0.id == entryID }) {
                BlipTimelineWorkoutList(
                    workouts: store.workouts(for: entry, in: day)
                )
            } else {
                ContentUnavailableView(
                    "Workouts unavailable",
                    systemImage: "figure.mixed.cardio"
                )
                .toolbar(.visible, for: .navigationBar)
            }
        }
    }

    private var selectedDayWorkouts: [BlipTimelineWorkout] {
        guard let day else { return [] }
        return store.workoutsByDateKey[day.dateKey] ?? []
    }

    @ToolbarContentBuilder
    private var timelineToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { store.moveSelection(byDays: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous day")
        }

        ToolbarItem(placement: .principal) {
            Button {
                selectToday()
                showsCalendar = false
            } label: {
                Text(store.selectedDate.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(BlipFont.heading(18, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(BlipColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to today")
            .accessibilityValue(
                calendar.isDateInToday(store.selectedDate)
                    ? "Today"
                    : store.selectedDate.formatted(date: .long, time: .omitted)
            )
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { showsCalendar.toggle() } label: {
                Image(systemName: showsCalendar ? "list.bullet" : "calendar")
            }
            .accessibilityLabel(showsCalendar ? "Show timeline" : "Show calendar")

            Button { store.moveSelection(byDays: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(calendar.isDateInToday(store.selectedDate))
            .accessibilityLabel("Next day")
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if let day, !day.orderedEntries.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(day.orderedEntries.enumerated()), id: \.element.id) { index, entry in
                            BlipTimelineEntryRow(
                                entry: entry,
                                workouts: store.workouts(for: entry, in: day),
                                isAllDay: day.entryCoversEntireDay(entry),
                                isFirst: index == 0,
                                isLast: index == day.orderedEntries.count - 1,
                                isSelected: selectedEntryID == entry.id,
                                selectEntry: { selectEntry(entry) }
                            )
                            .id(entry.id)
                            .contextMenu {
                                Button {
                                    editEntry(entry.id)
                                } label: {
                                    Label("Edit checkpoint", systemImage: "pencil")
                                }
                                Button {
                                    let midpoint = entry.endDate.map {
                                        entry.startDate.addingTimeInterval(
                                            $0.timeIntervalSince(entry.startDate) / 2
                                        )
                                    }
                                    if let midpoint { store.splitEntry(id: entry.id, at: midpoint) }
                                } label: {
                                    Label("Split in half", systemImage: "rectangle.split.2x1")
                                }
                                .disabled(entry.endDate == nil)
                                Button(role: .destructive) {
                                    store.deleteEntry(id: entry.id)
                                } label: {
                                    Label("Delete checkpoint", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .onChange(of: selectedEntryID) { _, entryID in
                    guard let entryID else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(entryID, anchor: .center)
                    }
                }
            }
        } else {
            VStack(spacing: 18) {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptySymbol)
                } description: {
                    Text(emptyDescription)
                }
                if !store.trackingEnabled {
                    Button("Enable Low-Power Tracking") {
                        store.enableTracking()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BlipColor.orange)
                }
            }
            .foregroundStyle(BlipColor.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 16)
        }
    }

    private var emptyTitle: String {
        day?.coverage == .partial ? "Waiting for movement" : "Not tracked"
    }

    private var emptySymbol: String {
        day?.coverage == .partial ? "location.fill.viewfinder" : "location.slash"
    }

    private var emptyDescription: String {
        if day?.coverage == .partial {
            return "Today is being tracked, but there are no meaningful visits or journeys yet."
        }
        return "This is different from a cold day: Blip has no reliable coverage for this date."
    }
}

private enum BlipTimelineEntryCenterAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

private extension VerticalAlignment {
    static let timelineEntryCenter = VerticalAlignment(BlipTimelineEntryCenterAlignment.self)
}

private struct BlipTimelineMarkerCenterPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil

    static func reduce(
        value: inout Anchor<CGPoint>?,
        nextValue: () -> Anchor<CGPoint>?
    ) {
        value = nextValue() ?? value
    }
}

private struct BlipTimelineEntryRow: View {
    private static let markerDiameter: CGFloat = 28

    let entry: BlipTimelineEntry
    let workouts: [BlipTimelineWorkout]
    let isAllDay: Bool
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool
    let selectEntry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: selectEntry) {
                HStack(alignment: .timelineEntryCenter, spacing: 12) {
                    timeColumn
                        .frame(width: 46, alignment: .trailing)
                        .alignmentGuide(.timelineEntryCenter) { dimensions in
                            dimensions[VerticalAlignment.center]
                        }

                    marker

                    if entry.kind == .visit {
                        visitContent
                    } else {
                        journeyContent
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Selects this item on the map")

            if !workouts.isEmpty {
                workoutAccessory
                    .zIndex(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, entry.kind == .visit ? 8 : 4)
        .backgroundPreferenceValue(BlipTimelineMarkerCenterPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    connector(center: proxy[anchor], size: proxy.size)
                }
            }
            .allowsHitTesting(false)
        }
        .background(
            isSelected ? BlipColor.orangeSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var workoutAccessory: some View {
        NavigationLink(value: workoutRoute) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: workouts[0].systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BlipTimelineWorkoutStyle.accent)
                    .frame(width: 32, height: 32)
                    .background(BlipTimelineWorkoutStyle.background, in: Circle())

                if workouts.count > 1 {
                    Text("\(workouts.count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(BlipColor.orange, in: Circle())
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            workouts.count == 1
                ? workouts[0].title
                : "\(workouts.count) workouts"
        )
        .accessibilityHint("Shows workout details")
    }

    private var workoutRoute: BlipTimelineSheetRoute {
        workouts.count == 1 ? .workout(workouts[0].id) : .workouts(entry.id)
    }

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isAllDay {
                Text("All day")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BlipColor.textPrimary)
            } else {
                Text(BlipTimelineTimeFormatter.string(from: entry.startDate))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BlipColor.textPrimary)
                if let endDate = entry.endDate {
                    Text(BlipTimelineTimeFormatter.string(from: endDate))
                        .font(.caption2)
                        .foregroundStyle(BlipColor.textSecondary)
                }
            }
        }
    }

    private var marker: some View {
        Group {
            if entry.kind == .visit, !entry.isHome, !entry.residentContacts.isEmpty {
                BlipTimelineCompactResidentMarker(
                    residents: entry.residentContacts,
                    size: Self.markerDiameter
                )
            } else {
                BlipTimelineMarkerGlyph(
                    systemName: entry.kind == .visit ? entry.placeSystemImage : transportSymbol,
                    size: 17
                )
                .foregroundStyle(entry.kind == .visit ? BlipColor.success : BlipColor.device)
                .frame(width: Self.markerDiameter, height: Self.markerDiameter)
                .background(BlipColor.surface, in: Circle())
            }
        }
        .frame(width: Self.markerDiameter, height: Self.markerDiameter)
        .alignmentGuide(.timelineEntryCenter) { dimensions in
            dimensions[VerticalAlignment.center]
        }
        .anchorPreference(
            key: BlipTimelineMarkerCenterPreferenceKey.self,
            value: .center
        ) { $0 }
    }

    private func connector(center: CGPoint, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if !isFirst {
                let height = center.y + 2
                Rectangle()
                    .fill(BlipColor.success.opacity(0.34))
                    .frame(width: 3, height: height)
                    .position(x: center.x, y: height / 2)
            }
            if !isLast {
                let height = max(0, size.height - center.y + 2)
                Rectangle()
                    .fill(BlipColor.success.opacity(0.34))
                    .frame(width: 3, height: height)
                    .position(x: center.x, y: center.y - 2 + height / 2)
            }
        }
    }

    private var visitContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
                .foregroundStyle(BlipColor.textPrimary)
                .alignmentGuide(.timelineEntryCenter) { dimensions in
                    dimensions[VerticalAlignment.center]
                }
            if let subtitle = entry.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(BlipColor.textSecondary)
            }
            if let duration = entry.duration {
                Text(durationText(duration))
                    .font(.caption)
                    .foregroundStyle(BlipColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var journeyContent: some View {
        HStack(spacing: 7) {
            Text(entry.title)
                .font(.subheadline.weight(.medium))
            if let duration = entry.duration,
               duration > 0 || entry.confidence != .inferred {
                Text(durationText(duration))
            }
            if let distance = entry.distanceMeters {
                Text(distanceText(distance))
            }
            if entry.confidence != .observed {
                Text(entry.confidence == .inferred ? "Estimated" : "Uncertain")
                    .foregroundStyle(
                        entry.confidence == .inferred ? BlipColor.device : BlipColor.warning
                    )
            }
        }
        .font(.caption)
        .foregroundStyle(BlipColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.timelineEntryCenter) { dimensions in
            dimensions[VerticalAlignment.center]
        }
    }

    private var transportSymbol: String {
        switch entry.transportMode ?? .unknown {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .driving: "car.fill"
        case .transit: "tram.fill"
        case .train: "train.side.front.car"
        case .ferry: "ferry.fill"
        case .flight: "airplane"
        case .unknown: "arrow.triangle.turn.up.right.circle"
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(duration / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1_000)
    }
}

private struct BlipTimelineWorkoutList: View {
    let workouts: [BlipTimelineWorkout]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(workouts.enumerated()), id: \.element.id) { index, workout in
                    NavigationLink(value: BlipTimelineSheetRoute.workout(workout.id)) {
                        HStack(spacing: 12) {
                            workoutIcon(workout, size: 34)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(workout.title)
                                    .font(.headline)
                                    .foregroundStyle(BlipColor.textPrimary)
                                Text(workoutTime(workout))
                                    .font(.caption)
                                    .foregroundStyle(BlipColor.textSecondary)
                            }

                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(BlipColor.textTertiary)
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < workouts.count - 1 {
                        Divider()
                            .overlay(BlipColor.hairline)
                            .padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .background(BlipColor.background)
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct BlipTimelineWorkoutDetail: View {
    let workout: BlipTimelineWorkout

    private var fields: [(label: String, value: String)] {
        var values: [(String, String)] = [
            ("Time", workoutTime(workout)),
            ("Duration", workoutDuration(workout.duration)),
        ]
        if let energy = workout.totalEnergyKilocalories {
            values.append(("Active energy", "\(Int(energy.rounded())) kcal"))
        }
        if let distance = workout.totalDistanceMeters {
            values.append(("Distance", workoutDistance(distance)))
        }
        if let isIndoor = workout.isIndoor {
            values.append(("Setting", isIndoor ? "Indoor" : "Outdoor"))
        }
        values.append(("Source", workout.sourceName))
        return values
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 13) {
                    workoutIcon(workout, size: 44)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(workout.title)
                            .font(BlipFont.heading(20, relativeTo: .title3))
                            .foregroundStyle(BlipColor.textPrimary)
                        Text(workout.startDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline)
                            .foregroundStyle(BlipColor.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(field.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BlipColor.textSecondary)
                            Spacer(minLength: 12)
                            Text(field.value)
                                .font(.body)
                                .foregroundStyle(BlipColor.textPrimary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 13)

                        if index < fields.count - 1 {
                            Divider().overlay(BlipColor.hairline)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(BlipColor.surfaceSoft, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(BlipColor.hairline, lineWidth: 1)
                }

                Text("Workout data is read from Apple Health and remains managed there.")
                    .font(.caption)
                    .foregroundStyle(BlipColor.textTertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BlipColor.background)
        .navigationTitle("Workout details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

private func workoutIcon(_ workout: BlipTimelineWorkout, size: CGFloat) -> some View {
    Image(systemName: workout.systemImage)
        .font(.system(size: size * 0.5, weight: .semibold))
        .foregroundStyle(BlipTimelineWorkoutStyle.accent)
        .frame(width: size, height: size)
        .background(BlipTimelineWorkoutStyle.background, in: Circle())
}

private func workoutTime(_ workout: BlipTimelineWorkout) -> String {
    "\(BlipTimelineTimeFormatter.string(from: workout.startDate))–\(BlipTimelineTimeFormatter.string(from: workout.endDate))"
}

private func workoutDuration(_ duration: TimeInterval) -> String {
    let minutes = max(1, Int(duration / 60))
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
}

private func workoutDistance(_ meters: Double) -> String {
    if meters < 1_000 { return "\(Int(meters.rounded())) m" }
    return String(format: "%.1f km", meters / 1_000)
}

private struct BlipTimelineCalendar: View {
    @Bindable var store: BlipTimelineStore
    let selectedDate: Date
    let selectDate: (Date) -> Void

    @State private var displayedMonth: Date
    private var calendar: Calendar { .autoupdatingCurrent }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    init(
        store: BlipTimelineStore,
        selectedDate: Date,
        selectDate: @escaping (Date) -> Void
    ) {
        self.store = store
        self.selectedDate = selectedDate
        self.selectDate = selectDate
        _displayedMonth = State(initialValue: selectedDate)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                monthHeader
                weekdayHeader
                monthGrid
                legend
            }
            .padding(16)
        }
    }

    private var monthHeader: some View {
        HStack {
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(BlipFont.heading(20, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(BlipColor.textPrimary)
            Spacer()
            Button { moveMonth(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 32)
            }
            Button { moveMonth(1) } label: {
                Image(systemName: "chevron.right").frame(width: 32, height: 32)
            }
            .disabled(isDisplayingCurrentMonth)
        }
        .buttonStyle(.plain)
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(Array(orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BlipColor.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 7) {
            ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayButton(date)
                } else {
                    Color.clear.frame(height: 42)
                }
            }
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let day = store.day(containing: date)
        let heat = day?.heat
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isFuture = date > calendar.startOfDay(for: Date())

        return Button {
            selectDate(date)
        } label: {
            Text(date.formatted(.dateTime.day()))
                .font(.subheadline.weight(isSelected ? .bold : .medium))
                .foregroundStyle(dayTextColor(heat: heat, isFuture: isFuture))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                    if let heat {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(heatColor(heat.level))
                    } else if !isFuture {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(BlipColor.surfaceSoft)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isSelected ? BlipColor.orange : BlipColor.hairlineHover,
                            lineWidth: isSelected ? 2 : (heat == nil && !isFuture ? 1 : 0)
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    if day?.coverage == .partial {
                        Circle()
                            .fill(BlipColor.orange)
                            .frame(width: 6, height: 6)
                            .padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(calendar.accessibleDateLabel(for: date))
        .accessibilityValue(accessibilityValue(for: day))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Cold")
                ForEach(BlipTimelineHeatLevel.allLevels, id: \.rawValue) { level in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(heatColor(level))
                        .frame(maxWidth: .infinity)
                        .frame(height: 10)
                }
                Text("Moving")
            }
            .font(.caption2)
            .foregroundStyle(BlipColor.textSecondary)

            Label("Outline means no reliable tracking data", systemImage: "square.dashed")
                .font(.caption2)
                .foregroundStyle(BlipColor.textSecondary)
        }
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthCells: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: displayedMonth) else {
            return []
        }
        let firstDay = interval.start
        let weekday = calendar.component(.weekday, from: firstDay)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let dates = dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        }
        return Array(repeating: nil, count: leading) + dates.map(Optional.some)
    }

    private var isDisplayingCurrentMonth: Bool {
        calendar.isDate(displayedMonth, equalTo: Date(), toGranularity: .month)
    }

    private func moveMonth(_ offset: Int) {
        guard let next = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else {
            return
        }
        let currentMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        displayedMonth = min(next, currentMonth)
    }

    private func dayTextColor(heat: BlipTimelineHeatScore?, isFuture: Bool) -> Color {
        if isFuture { return BlipColor.textTertiary.opacity(0.55) }
        guard let heat else { return BlipColor.textSecondary }
        switch heat.level {
        case .cold, .cool, .warm:
            return Color(hex: 0x2C2A28)
        case .hot, .intense:
            return .white
        }
    }

    private func heatColor(_ level: BlipTimelineHeatLevel) -> Color {
        switch level {
        case .cold: Color(hex: 0xDCE9E5)
        case .cool: Color(hex: 0xA9D4C3)
        case .warm: Color(hex: 0xF2C86B)
        case .hot: Color(hex: 0xED8A4C)
        case .intense: BlipColor.orange
        }
    }

    private func accessibilityValue(for day: BlipTimelineDay?) -> String {
        guard let day else { return "Not tracked" }
        if day.coverage == .untracked { return "Not tracked" }
        guard let heat = day.heat else { return "Movement unavailable" }
        return day.coverage == .partial
            ? "\(heat.level.title), partial day"
            : heat.level.title
    }
}

private struct BlipTimelineExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct BlipTimelineShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct BlipTimelineControls: View {
    @Bindable var store: BlipTimelineStore
    let export: () -> Void
    let deleteEverything: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Tracking") {
                    LabeledContent("Status", value: store.trackingState.title)
                    if store.trackingEnabled {
                        LabeledContent(
                            "Detailed drives",
                            value: store.backgroundCaptureStatus.title
                        )
                    }
                    LabeledContent("GPS burst", value: store.isActivelySampling ? "Active" : "Sleeping")
                    if let lastSampleAt = store.lastSampleAt {
                        LabeledContent("Last checkpoint") {
                            Text(lastSampleAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if store.trackingEnabled {
                        Button("Turn Tracking Off", role: .destructive) {
                            store.disableTracking()
                        }
                    } else {
                        Button("Enable Low-Power Tracking") {
                            store.enableTracking()
                        }
                    }
                    if store.trackingState == .denied || store.trackingState == .whenInUseOnly {
                        Button("Open Location Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                Section("Locations sync") {
                    LabeledContent("Queued changes", value: String(store.pendingSyncCount))
                    if let lastSyncAt = store.lastSyncAt {
                        LabeledContent("Last sync") {
                            Text(lastSyncAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if let persistenceError = store.persistenceError {
                        Text(persistenceError)
                            .font(.caption)
                            .foregroundStyle(BlipColor.warning)
                    }
                    if let syncError = store.syncError {
                        Text(syncError)
                            .font(.caption)
                            .foregroundStyle(BlipColor.warning)
                    }
                    Button(store.isSyncing ? "Syncing…" : "Sync Now") {
                        Task { await store.synchronizeWithCloud() }
                    }
                    .disabled(store.isSyncing)
                }

                Section("Your data") {
                    Button {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            export()
                        }
                    } label: {
                        Label("Export Timeline as JSON", systemImage: "square.and.arrow.up")
                    }
                    if let day = store.selectedDay {
                        Button(role: .destructive) {
                            store.deleteDay(dateKey: day.dateKey)
                        } label: {
                            Label("Delete Selected Day", systemImage: "calendar.badge.minus")
                        }
                    }
                    Button(role: .destructive) {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(250))
                            deleteEverything()
                        }
                    } label: {
                        Label("Delete Timeline Everywhere", systemImage: "trash")
                    }
                }

                Section {
                    Text("Most of the day Blip listens only for Apple’s low-power visit and significant-location signals. A coarse GPS burst wakes temporarily when movement begins; Motion is read only during that burst.")
                        .font(.caption)
                        .foregroundStyle(BlipColor.textSecondary)
                }
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension BlipTimelineStore {
    func backfillAppleMapsMetadataForSavedPlaces() async {
        defer { persistLedger() }
        for place in savedPlaces where place.mapItemIdentifier == nil {
            guard !place.isHome,
                  !["Home", "Visited place", "Current place"].contains(place.title) else {
                continue
            }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = place.title
            request.resultTypes = [.pointOfInterest]
            request.region = MKCoordinateRegion(
                center: place.coordinate.coordinate,
                latitudinalMeters: 600,
                longitudinalMeters: 600
            )
            guard let response = try? await MKLocalSearch(request: request).start() else { continue }
            let normalizedTitle = normalizedPlaceName(place.title)
            let matches = response.mapItems.compactMap { mapItem -> (MKMapItem, Double)? in
                guard normalizedPlaceName(mapItem.name ?? "") == normalizedTitle else { return nil }
                let mapCoordinate = BlipTimelineCoordinate(
                    latitude: mapItem.location.coordinate.latitude,
                    longitude: mapItem.location.coordinate.longitude
                )
                let distance = BlipTimelineGeometry.distanceMeters(
                    place.coordinate,
                    mapCoordinate
                )
                return distance <= 180 ? (mapItem, distance) : nil
            }.sorted { $0.1 < $1.1 }
            guard let match = matches.first,
                  matches.count == 1 || matches[1].1 - match.1 >= 30 else { continue }
            let mapCoordinate = BlipTimelineCoordinate(
                latitude: match.0.location.coordinate.latitude,
                longitude: match.0.location.coordinate.longitude
            )
            enrichSavedPlace(
                id: place.id,
                mapCoordinate: mapCoordinate,
                mapItemIdentifier: match.0.identifier?.rawValue,
                pointOfInterestCategory: match.0.pointOfInterestCategory?.rawValue,
                iconSystemName: BlipTimelinePlaceIcon.symbol(
                    for: match.0.pointOfInterestCategory
                )
            )
        }
    }

    private func normalizedPlaceName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}

private enum BlipTimelinePlaceRole: String, CaseIterable, Identifiable {
    case regular
    case home

    var id: Self { self }
    var title: String { self == .home ? "Home" : "Regular place" }
}

private enum BlipTimelinePlaceScope: String, CaseIterable, Identifiable {
    case thisVisit
    case remember

    var id: Self { self }
    var title: String {
        switch self {
        case .thisVisit: "Just this visit"
        case .remember: "Remember for future visits"
        }
    }
}

private struct BlipTimelinePlaceCandidate: Identifiable, Equatable {
    let id: String
    let savedPlaceID: String?
    let name: String
    let address: String
    let coordinate: BlipTimelineCoordinate
    let mapItemIdentifier: String?
    let category: String?
    let iconSystemName: String
    let distanceMeters: Double
    let isHome: Bool
    let residentContacts: [BlipTimelineResidentReference]

    init(mapItem: MKMapItem, relativeTo observedCoordinate: BlipTimelineCoordinate) {
        let coordinate = BlipTimelineCoordinate(
            latitude: mapItem.location.coordinate.latitude,
            longitude: mapItem.location.coordinate.longitude
        )
        let address = mapItem.addressRepresentations?.fullAddress(
            includingRegion: true,
            singleLine: true
        ) ?? mapItem.address?.fullAddress ?? ""
        let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name?.isEmpty == false ? name! : address
        self.address = address
        self.coordinate = coordinate
        self.mapItemIdentifier = mapItem.identifier?.rawValue
        self.category = mapItem.pointOfInterestCategory?.rawValue
        self.iconSystemName = BlipTimelinePlaceIcon.symbol(
            for: mapItem.pointOfInterestCategory
        )
        self.distanceMeters = BlipTimelineGeometry.distanceMeters(
            observedCoordinate,
            coordinate
        )
        self.savedPlaceID = nil
        self.isHome = false
        self.residentContacts = []
        self.id = mapItem.identifier?.rawValue
            ?? "map-\(coordinate.latitude)-\(coordinate.longitude)-\(self.name)"
    }

    init(savedPlace: BlipTimelineSavedPlace, relativeTo observedCoordinate: BlipTimelineCoordinate) {
        id = "saved-\(savedPlace.id)"
        savedPlaceID = savedPlace.id
        name = savedPlace.title
        address = savedPlace.subtitle ?? "Saved place"
        coordinate = savedPlace.mapCoordinate ?? savedPlace.coordinate
        mapItemIdentifier = savedPlace.mapItemIdentifier
        category = savedPlace.pointOfInterestCategory
        iconSystemName = savedPlace.iconSystemName
            ?? (savedPlace.isHome ? "house.fill" : "mappin")
        distanceMeters = BlipTimelineGeometry.distanceMeters(
            observedCoordinate,
            savedPlace.coordinate
        )
        isHome = savedPlace.isHome
        residentContacts = savedPlace.residentContacts
    }

    var distanceDescription: String {
        if distanceMeters < 1 { return "At recorded location" }
        if distanceMeters < 1_000 { return "\(Int(distanceMeters.rounded())) m away" }
        return String(format: "%.1f km away", distanceMeters / 1_000)
    }
}

private struct BlipTimelinePlaceCandidateRow: View {
    let candidate: BlipTimelinePlaceCandidate

    var body: some View {
        HStack(spacing: 12) {
            if !candidate.isHome, !candidate.residentContacts.isEmpty {
                BlipTimelineCompactResidentMarker(
                    residents: candidate.residentContacts,
                    size: 28
                )
            } else {
                BlipTimelineMarkerGlyph(systemName: candidate.iconSystemName, size: 18)
                    .foregroundStyle(BlipColor.orange)
                    .frame(width: 28, height: 28)
                    .background(BlipColor.orangeSoft, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(BlipColor.textPrimary)
                Text([candidate.address, candidate.distanceDescription]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(BlipColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private enum BlipTimelinePlaceIconPickerTab: String, CaseIterable, Identifiable {
    case emoji = "Emoji"
    case symbols = "Symbols"

    var id: Self { self }
}

private enum BlipTimelineRecentEmojiStore {
    private static let defaultsKey = "blip.timeline.recent-place-emojis"
    private static let maximumCount = 48

    static var values: [String] {
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            .compactMap(BlipTimelinePlaceIcon.customEmoji(from:))
    }

    static func record(_ emoji: String) -> [String] {
        var updated = values.filter { $0 != emoji }
        updated.insert(emoji, at: 0)
        if updated.count > maximumCount {
            updated.removeLast(updated.count - maximumCount)
        }
        UserDefaults.standard.set(updated, forKey: defaultsKey)
        return updated
    }
}

private struct BlipTimelinePlaceIconPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab: BlipTimelinePlaceIconPickerTab
    @State private var query = ""
    @State private var emojiCategory: BlipTimelineEmojiCategory
    @State private var recentEmojis: [String]

    private let columns = [
        GridItem(.adaptive(minimum: 48, maximum: 58), spacing: 10),
    ]

    init(selection: Binding<String>) {
        _selection = selection
        _tab = State(initialValue: BlipTimelinePlaceIcon.emoji(
            from: selection.wrappedValue
        ) == nil ? .symbols : .emoji)
        let selectedEmoji = BlipTimelinePlaceIcon.emoji(from: selection.wrappedValue)
        let selectedCategory = BlipTimelinePlaceIcon.emojiChoices.first {
            $0.emoji == selectedEmoji
        }?.category
        _emojiCategory = State(initialValue: selectedCategory ?? .smileys)
        _recentEmojis = State(initialValue: BlipTimelineRecentEmojiStore.values)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker("Icon type", selection: $tab) {
                    ForEach(BlipTimelinePlaceIconPickerTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                searchField

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        if tab == .emoji {
                            ForEach(filteredEmojiChoices) { choice in
                                iconCell(
                                    value: choice.storedValue,
                                    title: choice.title,
                                    size: 30
                                )
                            }
                        } else {
                            ForEach(filteredSymbolChoices) { choice in
                                iconCell(
                                    value: choice.symbol,
                                    title: choice.title,
                                    size: 23
                                )
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    if visibleChoiceCount == 0 {
                        Group {
                            if tab == .emoji, query.isEmpty, emojiCategory == .recent {
                                ContentUnavailableView(
                                    "No Recent Emoji",
                                    systemImage: "clock",
                                    description: Text("Emoji you choose will appear here.")
                                )
                            } else {
                                ContentUnavailableView.search(text: query)
                            }
                        }
                        .padding(.top, 60)
                    }
                }
                .scrollDismissesKeyboard(.interactively)

                if tab == .emoji {
                    emojiCategoryBar
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: tab) { _, _ in query = "" }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(BlipColor.textTertiary)
            TextField(
                tab == .emoji ? "Search or paste an emoji" : "Search symbols",
                text: $query
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(BlipColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(BlipColor.surfaceSoft, in: RoundedRectangle(cornerRadius: 12))
    }

    private var filteredEmojiChoices: [BlipTimelinePlaceIcon.EmojiChoice] {
        BlipTimelinePlaceIcon.filteredEmojiChoices(
            query: query,
            category: emojiCategory,
            recentEmojis: recentEmojis
        )
    }

    private var filteredSymbolChoices: [BlipTimelinePlaceIcon.SymbolChoice] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return BlipTimelinePlaceIcon.symbolChoices }
        return BlipTimelinePlaceIcon.symbolChoices.filter {
            normalized($0.searchableText).contains(normalizedQuery)
        }
    }

    private var visibleChoiceCount: Int {
        tab == .emoji ? filteredEmojiChoices.count : filteredSymbolChoices.count
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .autoupdatingCurrent
        )
    }

    private var emojiCategoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(BlipTimelineEmojiCategory.allCases) { category in
                    Button {
                        emojiCategory = category
                    } label: {
                        Image(systemName: category.systemName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                emojiCategory == category
                                    ? BlipColor.orange
                                    : BlipColor.textSecondary
                            )
                            .frame(width: 34, height: 32)
                            .background(
                                emojiCategory == category
                                    ? BlipColor.orangeSoft
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.title)
                    .accessibilityAddTraits(
                        emojiCategory == category ? .isSelected : []
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 2, for: .scrollContent)
        .frame(height: 36)
    }

    private func iconCell(value: String, title: String, size: CGFloat) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
            if let emoji = BlipTimelinePlaceIcon.emoji(from: value) {
                recentEmojis = BlipTimelineRecentEmojiStore.record(emoji)
            }
            dismiss()
        } label: {
            BlipTimelineMarkerGlyph(systemName: value, size: size)
                .foregroundStyle(isSelected ? BlipColor.orange : BlipColor.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(
                    isSelected ? BlipColor.orangeSoft : BlipColor.surfaceSoft,
                    in: RoundedRectangle(cornerRadius: 13)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(
                            isSelected ? BlipColor.orange : Color.clear,
                            lineWidth: 1.5
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(BlipColor.orange)
                            .background(BlipColor.surface, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct BlipTimelineEntryEditor: View {
    @Bindable var store: BlipTimelineStore
    let entry: BlipTimelineEntry
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var subtitle: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isOngoing: Bool
    @State private var transportMode: BlipTimelineTransportMode
    @State private var isHome: Bool
    @State private var placeRole: BlipTimelinePlaceRole
    @State private var placeScope: BlipTimelinePlaceScope
    @State private var selectedSavedPlaceID: String?
    @State private var selectedCandidateID: String?
    @State private var placeCoordinate: BlipTimelineCoordinate?
    @State private var mapItemIdentifier: String?
    @State private var pointOfInterestCategory: String?
    @State private var iconSystemName: String
    @State private var residentContacts: [BlipTimelineResidentReference]
    @State private var showsIconPicker = false
    @State private var showsContactPicker = false
    @State private var nearbyCandidates: [BlipTimelinePlaceCandidate] = []
    @State private var searchCandidates: [BlipTimelinePlaceCandidate] = []
    @State private var placeQuery = ""
    @State private var isLoadingNearbyPlaces = false
    @State private var isSearchingPlaces = false
    @State private var placeSearchError: String?
    @State private var splitDate: Date
    @State private var confirmsDelete = false

    init(store: BlipTimelineStore, entry: BlipTimelineEntry) {
        self.store = store
        self.entry = entry
        let end = entry.endDate ?? entry.startDate.addingTimeInterval(30 * 60)
        _title = State(initialValue: entry.title)
        _subtitle = State(initialValue: entry.subtitle ?? "")
        _startDate = State(initialValue: entry.startDate)
        _endDate = State(initialValue: end)
        _isOngoing = State(initialValue: entry.kind == .visit && entry.endDate == nil)
        _transportMode = State(initialValue: entry.transportMode ?? .unknown)
        _isHome = State(initialValue: entry.isHome)
        _placeRole = State(initialValue: entry.isHome ? .home : .regular)
        _placeScope = State(initialValue: entry.placeID == nil ? .thisVisit : .remember)
        _selectedSavedPlaceID = State(initialValue: entry.placeID)
        _selectedCandidateID = State(initialValue: entry.placeID.map { "saved-\($0)" })
        _placeCoordinate = State(initialValue: entry.placeCoordinate)
        _mapItemIdentifier = State(initialValue: entry.mapItemIdentifier)
        _pointOfInterestCategory = State(initialValue: entry.placeCategory)
        _iconSystemName = State(initialValue: entry.placeSystemImage)
        _residentContacts = State(initialValue: entry.residentContacts)
        _splitDate = State(initialValue: entry.startDate.addingTimeInterval(
            max(60, end.timeIntervalSince(entry.startDate) / 2)
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(entry.kind == .visit ? "Place" : "Journey") {
                    TextField("Name", text: $title)
                    if entry.kind == .visit {
                        TextField("Area or note", text: $subtitle)
                        Picker("Place type", selection: $placeRole) {
                            ForEach(BlipTimelinePlaceRole.allCases) { role in
                                Label(
                                    role.title,
                                    systemImage: role == .home ? "house.fill" : "mappin"
                                ).tag(role)
                            }
                        }
                        .onChange(of: placeRole) { _, role in
                            isHome = role == .home
                            if role == .home {
                                placeScope = .remember
                                if title == "Visited place" || title == "Current place"
                                    || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    title = "Home"
                                }
                                if iconSystemName == "mappin" { iconSystemName = "house.fill" }
                            }
                        }

                        Button {
                            showsIconPicker = true
                        } label: {
                            HStack(spacing: 10) {
                                Text("Icon")
                                    .foregroundStyle(BlipColor.textPrimary)
                                Spacer()
                                BlipTimelineMarkerGlyph(
                                    systemName: iconSystemName,
                                    size: 20
                                )
                                Text(BlipTimelinePlaceIcon.title(for: iconSystemName))
                                    .foregroundStyle(BlipColor.textSecondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(BlipColor.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Picker("Transport", selection: $transportMode) {
                            ForEach(BlipTimelineTransportMode.allCasesForEditing, id: \.self) { mode in
                                Text(mode.editingTitle).tag(mode)
                            }
                        }
                    }
                }

                if entry.kind == .visit, entry.coordinate != nil {
                    residentSection
                    placePickerSections
                }

                Section("Time") {
                    DatePicker("Start", selection: $startDate)
                    if entry.kind == .visit {
                        Toggle("Ongoing", isOn: $isOngoing)
                    }
                    if !isOngoing {
                        DatePicker("End", selection: $endDate, in: startDate...)
                    }
                }

                if !isOngoing, endDate.timeIntervalSince(startDate) >= 2 * 60 {
                    Section("Split") {
                        DatePicker(
                            "Split at",
                            selection: $splitDate,
                            in: startDate.addingTimeInterval(60)...endDate.addingTimeInterval(-60)
                        )
                        Button("Split Checkpoint") {
                            store.splitEntry(id: entry.id, at: splitDate)
                            dismiss()
                        }
                    }
                }

                Section("Merge") {
                    Button("Merge with Previous") {
                        store.mergeEntry(id: entry.id, towardNext: false)
                        dismiss()
                    }
                    .disabled(!store.canMergeEntry(id: entry.id, towardNext: false))
                    Button("Merge with Next") {
                        store.mergeEntry(id: entry.id, towardNext: true)
                        dismiss()
                    }
                    .disabled(!store.canMergeEntry(id: entry.id, towardNext: true))
                }

                Section {
                    Button("Delete Checkpoint", role: .destructive) {
                        confirmsDelete = true
                    }
                }
            }
            .navigationTitle("Edit Checkpoint")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: entry.id) {
                await loadNearbyPlaces()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if entry.kind == .visit {
                            store.updateVisitEntry(
                                id: entry.id,
                                title: title,
                                subtitle: subtitle.isEmpty ? nil : subtitle,
                                startDate: startDate,
                                endDate: isOngoing ? nil : endDate,
                                isHome: placeRole == .home,
                                selectedSavedPlaceID: selectedSavedPlaceID,
                                placeCoordinate: placeCoordinate,
                                mapItemIdentifier: mapItemIdentifier,
                                pointOfInterestCategory: pointOfInterestCategory,
                                iconSystemName: iconSystemName,
                                residentContacts: residentContacts,
                                rememberPlace: placeScope == .remember
                                    || !residentContacts.isEmpty
                            )
                        } else {
                            store.updateEntry(
                                id: entry.id,
                                title: title,
                                subtitle: subtitle.isEmpty ? nil : subtitle,
                                startDate: startDate,
                                endDate: isOngoing ? nil : endDate,
                                transportMode: transportMode,
                                isHome: false
                            )
                        }
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(
                "Delete this checkpoint?",
                isPresented: $confirmsDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Checkpoint", role: .destructive) {
                    store.deleteEntry(id: entry.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showsIconPicker) {
                BlipTimelinePlaceIconPicker(selection: $iconSystemName)
            }
#if os(iOS)
            .background {
                BlipTimelineContactPickerPresenter(
                    residents: $residentContacts,
                    isPresented: $showsContactPicker
                )
                .frame(width: 0, height: 0)
            }
#endif
            .onChange(of: residentContacts) { _, residents in
                if !residents.isEmpty { placeScope = .remember }
            }
        }
    }

    @ViewBuilder
    private var residentSection: some View {
        Section("People who live here") {
            if residentContacts.isEmpty {
                Text("Assign contacts to show whose place this is on the map and Timeline.")
                    .foregroundStyle(BlipColor.textSecondary)
            } else {
                ForEach(residentContacts) { resident in
                    HStack(spacing: 10) {
                        BlipTimelineResidentAvatar(resident: resident, size: 30)
                        Text(resident.displayName)
                        Spacer()
                        Button(role: .destructive) {
                            residentContacts.removeAll { $0.id == resident.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(resident.displayName)")
                    }
                }
            }

#if os(iOS)
            Button {
                showsContactPicker = true
            } label: {
                Label(
                    residentContacts.isEmpty ? "Add people" : "Add more people",
                    systemImage: "person.crop.circle.badge.plus"
                )
            }
#endif
            Text("This saves the place for future visits. Contact photos remain only on this device.")
                .font(.caption)
                .foregroundStyle(BlipColor.textSecondary)
        }
    }

    @ViewBuilder
    private var placePickerSections: some View {
        let observedCoordinate = entry.coordinate!
        let savedCandidates = store.savedPlaces.map {
            BlipTimelinePlaceCandidate(savedPlace: $0, relativeTo: observedCoordinate)
        }.sorted { $0.distanceMeters < $1.distanceMeters }

        if !savedCandidates.isEmpty {
            Section("Saved places") {
                ForEach(savedCandidates.prefix(6)) { candidate in
                    Button { select(candidate) } label: {
                        candidateRow(candidate)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Section("Suggested nearby") {
            if isLoadingNearbyPlaces {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking around the recorded location…")
                        .foregroundStyle(BlipColor.textSecondary)
                }
            } else if nearbyCandidates.isEmpty {
                Text("No nearby Apple Maps places found.")
                    .foregroundStyle(BlipColor.textSecondary)
            } else {
                ForEach(nearbyCandidates.prefix(6)) { candidate in
                    Button { select(candidate) } label: {
                        candidateRow(candidate)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Section("Search Apple Maps") {
            HStack {
                TextField("Place or address", text: $placeQuery)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { Task { await searchPlaces() } }
                if isSearchingPlaces {
                    ProgressView()
                } else {
                    Button("Search") { Task { await searchPlaces() } }
                        .disabled(placeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let placeSearchError {
                Text(placeSearchError)
                    .font(.caption)
                    .foregroundStyle(BlipColor.warning)
            }
            ForEach(searchCandidates) { candidate in
                Button { select(candidate) } label: {
                    candidateRow(candidate)
                }
                .buttonStyle(.plain)
            }
        }

        Section("Apply selection") {
            Picker("Use for", selection: $placeScope) {
                ForEach(BlipTimelinePlaceScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .disabled(placeRole == .home)
            Text("The recorded GPS location is always preserved separately from the selected place.")
                .font(.caption)
                .foregroundStyle(BlipColor.textSecondary)
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: BlipTimelinePlaceCandidate) -> some View {
        HStack(spacing: 8) {
            BlipTimelinePlaceCandidateRow(candidate: candidate)
            if selectedCandidateID == candidate.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BlipColor.success)
            }
        }
    }

    private func select(_ candidate: BlipTimelinePlaceCandidate) {
        title = candidate.name
        subtitle = candidate.address == "Saved place" ? "" : candidate.address
        selectedSavedPlaceID = candidate.savedPlaceID
        selectedCandidateID = candidate.id
        placeCoordinate = candidate.coordinate
        mapItemIdentifier = candidate.mapItemIdentifier
        pointOfInterestCategory = candidate.category
        iconSystemName = candidate.iconSystemName
        residentContacts = candidate.residentContacts
        placeRole = candidate.isHome ? .home : .regular
        isHome = candidate.isHome
        if candidate.savedPlaceID != nil { placeScope = .remember }
    }

    @MainActor
    private func loadNearbyPlaces() async {
        guard let observedCoordinate = entry.coordinate, !isLoadingNearbyPlaces else { return }
        isLoadingNearbyPlaces = true
        defer { isLoadingNearbyPlaces = false }
        do {
            let request = MKLocalPointsOfInterestRequest(
                center: observedCoordinate.coordinate,
                radius: 350
            )
            let response = try await MKLocalSearch(request: request).start()
            nearbyCandidates = uniqueCandidates(response.mapItems.map {
                BlipTimelinePlaceCandidate(mapItem: $0, relativeTo: observedCoordinate)
            }).sorted { $0.distanceMeters < $1.distanceMeters }
        } catch {
            nearbyCandidates = []
        }
    }

    @MainActor
    private func searchPlaces() async {
        guard let observedCoordinate = entry.coordinate else { return }
        let query = placeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearchingPlaces else { return }
        isSearchingPlaces = true
        placeSearchError = nil
        defer { isSearchingPlaces = false }
        do {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = [.pointOfInterest, .address]
            request.region = MKCoordinateRegion(
                center: observedCoordinate.coordinate,
                latitudinalMeters: 5_000,
                longitudinalMeters: 5_000
            )
            let response = try await MKLocalSearch(request: request).start()
            searchCandidates = Array(uniqueCandidates(response.mapItems.map {
                BlipTimelinePlaceCandidate(mapItem: $0, relativeTo: observedCoordinate)
            }).prefix(8))
            if searchCandidates.isEmpty {
                placeSearchError = "No matching places found. Try a more specific name or address."
            }
        } catch {
            placeSearchError = "Apple Maps search is unavailable right now."
            searchCandidates = []
        }
    }

    private func uniqueCandidates(
        _ candidates: [BlipTimelinePlaceCandidate]
    ) -> [BlipTimelinePlaceCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted && !$0.name.isEmpty }
    }

}

private extension BlipTimelineHeatLevel {
    static let allLevels: [Self] = [.cold, .cool, .warm, .hot, .intense]

    var title: String {
        switch self {
        case .cold: "Cold day"
        case .cool: "Light movement"
        case .warm: "Active day"
        case .hot: "Very active day"
        case .intense: "High-movement day"
        }
    }
}

private extension BlipTimelineTransportMode {
    static let allCasesForEditing: [Self] = [
        .walking, .cycling, .driving, .transit, .train, .ferry, .flight, .unknown,
    ]

    var editingTitle: String {
        switch self {
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .driving: "Driving"
        case .transit: "Public transit"
        case .train: "Train"
        case .ferry: "Ferry"
        case .flight: "Flight"
        case .unknown: "Unknown"
        }
    }
}

private extension Calendar {
    func accessibleDateLabel(for date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}
#endif
