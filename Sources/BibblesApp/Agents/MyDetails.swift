#if BIBBLES_DEVELOPER
import Contacts
import Foundation
import Security

/// The user's own details for filling forms. Stored only in this Mac's
/// Keychain; matched to form fields ON THE MAC. The AI never receives these
/// values, only placeholders like {{email}}.
struct MyDetails: Codable, Equatable {
    var firstName = ""
    var lastName = ""
    var email = ""
    var phone = ""
    var street = ""
    var city = ""
    var postalCode = ""
    var country = ""
    var company = ""
    var jobTitle = ""
    var website = ""

    enum Key: String, CaseIterable, Identifiable {
        case firstName, lastName, fullName, email, phone, street, city, postalCode, country, company, jobTitle, website

        var id: String { rawValue }

        /// The placeholder the planner may use: {{email}}.
        var token: String { "{{\(rawValue)}}" }

        var title: String {
            switch self {
            case .firstName: return "First name"
            case .lastName: return "Last name"
            case .fullName: return "Full name"
            case .email: return "Email"
            case .phone: return "Phone"
            case .street: return "Street address"
            case .city: return "City"
            case .postalCode: return "Postal code"
            case .country: return "Country"
            case .company: return "Company"
            case .jobTitle: return "Job title"
            case .website: return "Website"
            }
        }
    }

    func value(_ key: Key) -> String {
        switch key {
        case .firstName: return firstName
        case .lastName: return lastName
        case .fullName: return [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        case .email: return email
        case .phone: return phone
        case .street: return street
        case .city: return city
        case .postalCode: return postalCode
        case .country: return country
        case .company: return company
        case .jobTitle: return jobTitle
        case .website: return website
        }
    }

    /// Stores the text as typed; `trimmed()` tidies it when saving.
    mutating func set(_ key: Key, _ value: String) {
        let trimmed = value
        switch key {
        case .firstName: firstName = trimmed
        case .lastName: lastName = trimmed
        case .fullName:
            let parts = trimmed.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            firstName = parts.first ?? ""
            lastName = parts.count > 1 ? parts[1] : ""
        case .email: email = trimmed
        case .phone: phone = trimmed
        case .street: street = trimmed
        case .city: city = trimmed
        case .postalCode: postalCode = trimmed
        case .country: country = trimmed
        case .company: company = trimmed
        case .jobTitle: jobTitle = trimmed
        case .website: website = trimmed
        }
    }

    func trimmed() -> MyDetails {
        var result = MyDetails()
        for key in Key.allCases where key != .fullName {
            result.set(key, value(key).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Keys that have a value (the planner only learns which exist, never the values).
    var availableKeys: [Key] { Key.allCases.filter { !value($0).isEmpty } }

    var isEmpty: Bool { availableKeys.isEmpty }

    /// Fills empty fields from another source (the Contacts card), keeping what the user typed.
    func merged(with other: MyDetails) -> MyDetails {
        var result = self
        for key in Key.allCases where key != .fullName && value(key).isEmpty && !other.value(key).isEmpty {
            result.set(key, other.value(key))
        }
        return result
    }
}

/// Keychain storage for My details (one item, this device only).
enum MyDetailsStore {
    static let defaultService = "com.bibbles.dev.profile"
    static var service = defaultService
    static let account = "my-details"
    /// Tests only: when set, the Keychain is never touched.
    static var testOverride: MyDetails??

    static func load() -> MyDetails {
        if let testOverride { return testOverride ?? MyDetails() }
        guard let text = DeveloperKeychain.readItem(service: service, account: account),
              let data = text.data(using: .utf8),
              let details = try? JSONDecoder().decode(MyDetails.self, from: data) else { return MyDetails() }
        return details
    }

    @discardableResult
    static func save(_ raw: MyDetails) -> Bool {
        let details = raw.trimmed()
        if testOverride != nil {
            testOverride = .some(details)
            return true
        }
        DeveloperKeychain.deleteItem(service: service, account: account)
        guard !details.isEmpty else { return true }
        guard let data = try? JSONEncoder().encode(details), let text = String(data: data, encoding: .utf8) else { return false }
        return DeveloperKeychain.addItem(text, service: service, account: account)
    }

    static func clear() {
        if testOverride != nil { testOverride = .some(nil); return }
        DeveloperKeychain.deleteItem(service: service, account: account)
    }
}

/// The "Me" card in Contacts, read only after the user presses the button
/// (macOS asks for Contacts permission once).
enum ContactsMeCard {
    enum Problem: LocalizedError {
        case denied, noMeCard
        var errorDescription: String? {
            switch self {
            case .denied: return "Bibbles needs Contacts access: System Settings → Privacy & Security → Contacts → Bibbles Dev."
            case .noMeCard: return "There's no “My Card” in Contacts. In Contacts, choose your card, then Card → Make This My Card."
            }
        }
    }

    static func load() async throws -> MyDetails {
        let store = CNContactStore()
        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { throw Problem.denied }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey,
                    CNContactPhoneNumbersKey, CNContactPostalAddressesKey, CNContactOrganizationNameKey,
                    CNContactJobTitleKey, CNContactUrlAddressesKey] as [CNKeyDescriptor]
        let me: CNContact
        do {
            me = try store.unifiedMeContactWithKeys(toFetch: keys)
        } catch {
            throw Problem.noMeCard
        }
        var details = MyDetails()
        details.firstName = me.givenName
        details.lastName = me.familyName
        details.email = (me.emailAddresses.first?.value as String?) ?? ""
        details.phone = me.phoneNumbers.first?.value.stringValue ?? ""
        if let address = me.postalAddresses.first?.value {
            details.street = address.street
            details.city = address.city
            details.postalCode = address.postalCode
            details.country = address.country
        }
        details.company = me.organizationName
        details.jobTitle = me.jobTitle
        details.website = (me.urlAddresses.first?.value as String?) ?? ""
        return details
    }
}

/// Which detail a form field asks for, decided on the Mac from its label
/// (many languages). Some fields are never filled, whatever the request.
enum MyDetailsMatcher {
    /// Passwords, payment, government IDs and codes: never filled by Bibbles.
    static let neverFill = ["password", "passwort", "contraseña", "mot de passe", "senha", "パスワード", "पासवर्ड", "passcode",
                            "card", "kreditkarte", "tarjeta", "carte", "cartão", "カード", "cvv", "cvc", "security code",
                            "expiry", "expiration", "iban", "bic", "swift", "routing", "account number", "bank",
                            "ssn", "social security", "passport", "pasaporte", "reisepass", "national id", "aadhaar",
                            "pan number", "tax id", "steuer", "otp", "one-time", "verification code", "verify code",
                            "captcha", "pin", "date of birth", "birthday", "geburtsdatum", "fecha de nacimiento"]

    /// Label words per detail, checked in this order (specific before general).
    static let synonyms: [(MyDetails.Key, [String])] = [
        (.email, ["email", "e-mail", "e mail", "mail address", "correo", "courriel", "メール", "ईमेल"]),
        (.phone, ["phone", "mobile", "telephone", "tel", "cell", "teléfono", "telefono", "telefon", "téléphone", "telefone",
                  "celular", "handy", "電話", "फ़ोन", "फोन", "मोबाइल"]),
        (.postalCode, ["zip", "postal", "postcode", "post code", "plz", "postleitzahl", "código postal", "code postal", "cep",
                       "pin code", "pincode", "郵便番号", "पिन कोड"]),
        (.firstName, ["first name", "firstname", "given name", "forename", "vorname", "nombre de pila", "prénom", "prenom",
                      "primeiro nome", "名", "पहला नाम"]),
        (.lastName, ["last name", "lastname", "surname", "family name", "nachname", "apellido", "apellidos", "nom de famille",
                     "sobrenome", "姓", "उपनाम"]),
        (.company, ["company", "organization", "organisation", "employer", "firma", "unternehmen", "empresa", "entreprise",
                    "société", "会社", "कंपनी"]),
        (.jobTitle, ["job title", "position", "role", "occupation", "berufsbezeichnung", "puesto", "cargo", "poste", "役職", "पद"]),
        (.website, ["website", "web site", "homepage", "url", "sitio web", "site web", "webseite"]),
        (.street, ["street", "address line", "address 1", "address", "straße", "strasse", "adresse", "dirección", "endereço",
                   "rua", "住所", "पता"]),
        (.city, ["city", "town", "stadt", "ort", "ciudad", "ville", "cidade", "市区町村", "शहर"]),
        (.country, ["country", "land", "país", "pays", "国", "देश"]),
        (.fullName, ["full name", "your name", "name", "nombre", "nom", "nome", "氏名", "お名前", "नाम"])
    ]

    static func isNeverFill(_ label: String) -> Bool {
        let folded = " " + ToolGateText.fold(label) + " "
        // "pin code" is a postal code in India; "PIN" alone is not.
        if folded.contains(" pin code ") || folded.contains(" pincode ") { return false }
        return neverFill.contains { phrase in
            let word = ToolGateText.fold(phrase)
            return ToolGateText.isUnspaced(phrase) ? label.contains(phrase) : folded.contains(" " + word + " ")
                || (word.count >= 5 && folded.contains(word))
        }
    }

    /// The detail a label asks for; nil when unknown or never filled.
    static func key(forLabel label: String) -> MyDetails.Key? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isNeverFill(trimmed) else { return nil }
        let folded = " " + ToolGateText.fold(trimmed) + " "
        // "Username" and "user name" belong to the account, not a person's name.
        if folded.contains(" username ") || folded.contains(" user name ") || folded.contains(" benutzername ") { return nil }
        // Japanese full-name labels contain the first-name character 名.
        if ["氏名", "お名前", "名前"].contains(where: trimmed.contains) { return .fullName }
        for (key, words) in synonyms {
            for word in words {
                let match = ToolGateText.isUnspaced(word) ? trimmed.contains(word) : folded.contains(" " + ToolGateText.fold(word) + " ")
                if match { return key }
            }
        }
        return nil
    }
}
#endif
