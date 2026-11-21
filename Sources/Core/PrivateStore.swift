import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Encrypted storage for personal details (household, health, skills, memories, conversation logs, family plan, supplies).
///
/// Normally (no passphrase):
/// - The file lives in this device's Application Support folder, never in the library or on a kit drive,
///   so it isn't copied with the drive, shared over Wi-Fi or found by the library scanner.
/// - It's sealed with AES-GCM. The key is in the Keychain, marked this-device-only on iPhone and iPad,
///   so a backup or copied file can't be opened anywhere else.
/// - It's excluded from iCloud and computer backups.
///
/// With a passphrase (Mac, running from a drive), so the same details open on any Mac the drive is plugged into:
/// - The sealed file moves into "Offline Kit Private" beside the app on the drive.
/// - Next to it, `household.key` holds the same data key wrapped (AES-GCM) with a key derived from the passphrase
///   (PBKDF2-HMAC-SHA256, 600,000 rounds, random salt). The passphrase itself is never stored.
/// - Each Mac caches the unwrapped key in its own Keychain under an item named for that drive's store, so it never
///   touches the Mac's own "household-key" item or its own local details. "Remember on this Mac" can be turned off.
/// - If the drive is lost, the passphrase is all that protects the details.
enum PrivateStore {
    // MARK: Where things are

    /// This device's own folder (today's location).
    static var localFolder: URL {
        #if DEBUG
        if let test = KitLocation.testHome { return test.appending(path: ".private", directoryHint: .isDirectory) }
        #endif
        return URL.applicationSupportDirectory.appending(path: "OfflineKit/Private", directoryHint: .isDirectory)
    }

    /// The folder beside the app on a kit drive, when running from one.
    static var driveFolder: URL? {
        KitLocation.portableRoot?.appending(path: "Offline Kit Private", directoryHint: .isDirectory)
    }

    static let fileName = "household.sealed"
    private static let wrappedKeyName = "household.key"

    /// The wrapped key on the drive, when a passphrase is set.
    static var wrappedKeyURL: URL? { driveFolder?.appending(path: wrappedKeyName) }

    /// True when this kit's details are protected by a passphrase and kept on the drive.
    static var usesPassphrase: Bool {
        guard let url = wrappedKeyURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Where the sealed details are read and written right now.
    static var folder: URL { usesPassphrase ? driveFolder! : localFolder }
    static var fileURL: URL { folder.appending(path: fileName) }

    /// A passphrase is set but this Mac doesn't have the key yet: ask for the passphrase before reading or saving.
    static var isLocked: Bool { usesPassphrase && currentKey() == nil }

    /// Passphrases can be turned on only when running from a drive (Mac).
    static var canUsePassphrase: Bool { driveFolder != nil }

    /// Where the private details are kept, in words, for every place the app mentions it.
    static var whereText: String {
        if usesPassphrase { return "Encrypted on this drive with your passphrase" }
        #if os(macOS)
        return "Private to this Mac"
        #else
        return "Private to this device"
        #endif
    }

    /// The drive's key is saved in this Mac's own Keychain ("Remember on this Mac"), not just open for this run.
    static var remembersKeyOnThisMac: Bool {
        guard usesPassphrase, let id = readWrapped()?.id else { return false }
        return readKey(account: driveAccount(id)) != nil
    }

    // MARK: Reading and writing

    static func load<T: Decodable>(_ type: T.Type) -> T? {
        guard let sealed = try? Data(contentsOf: fileURL), let key = try? key(create: false),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try writeSealed(data, key: try key(create: true), to: folder)
    }

    private static func writeSealed(_ plain: Data, key: SymmetricKey, to folder: URL) throws {
        let sealed = try AES.GCM.seal(plain, using: key).combined!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUnlessOpen)
        #endif
        try sealed.write(to: folder.appending(path: fileName), options: options)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Deletes the details in use and their key. Nothing personal is left behind. With a passphrase that's the drive's
    /// details (and this Mac's cached key for them); this Mac's own separate details, if any, are left alone.
    static func erase() {
        if usesPassphrase, let driveFolder, let wrappedKeyURL {
            if let wrapped = readWrapped() { deleteKey(account: driveAccount(wrapped.id)) }
            try? FileManager.default.removeItem(at: driveFolder.appending(path: fileName))
            try? FileManager.default.removeItem(at: wrappedKeyURL)
            sessionKey = nil
            return
        }
        try? FileManager.default.removeItem(at: localFolder.appending(path: fileName))
        deleteKey(account: localAccount)
    }

    // MARK: Passphrase

    enum PassphraseError: LocalizedError {
        case notOnDrive, locked, wrongPassphrase, damaged, thisMacHasItsOwn
        var errorDescription: String? {
            switch self {
            case .notOnDrive: "A passphrase can be set when Offline Kit runs from a USB drive."
            case .locked: "Enter the passphrase first."
            case .wrongPassphrase: "That passphrase didn’t work. Check it and try again."
            case .damaged: "The passphrase file on this drive is damaged, so the details can’t be opened."
            case .thisMacHasItsOwn: "This Mac already has its own private details, so they can’t be moved here. Stop using the passphrase on the Mac where it was set up."
            }
        }
    }

    /// The passphrase-wrapped data key, as stored on the drive.
    private struct WrappedKey: Codable {
        var version = 1
        /// Names this drive's store, so each Mac caches its key separately.
        var id: String
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var salt: Data
        /// AES-GCM sealed data key, with `id` as authenticated data.
        var box: Data
    }

    static let iterations = 600_000

    /// Turns the passphrase on: wraps the data key, moves the details to the drive. Safe to interrupt: the details
    /// on this Mac stay in charge until the key file is written, and are removed only after that.
    static func enablePassphrase(_ passphrase: String) throws {
        guard let driveFolder, let wrappedKeyURL else { throw PassphraseError.notOnDrive }
        // Already on: changing it goes through `changePassphrase(from:to:)`, which checks the current one.
        guard !usesPassphrase else { return }
        let key = try key(create: true)
        let localFile = localFolder.appending(path: fileName)
        let id = UUID().uuidString
        try writeKey(key.withUnsafeBytes { Data($0) }, account: driveAccount(id))
        if let sealed = try? Data(contentsOf: localFile) {
            let box = try AES.GCM.SealedBox(combined: sealed)
            try writeSealed(try AES.GCM.open(box, using: key), key: key, to: driveFolder)
        }
        #if DEBUG
        // Test hook: -slowPassphraseSetup YES stands in for a slow Mac, where the key derivation below takes seconds.
        if UserDefaults.standard.bool(forKey: "slowPassphraseSetup") { Thread.sleep(forTimeInterval: 1.5) }
        #endif
        try writeWrapped(wrap(key, passphrase: passphrase, id: id), to: wrappedKeyURL)
        // From here the drive is in charge; this Mac keeps the key under the drive's own Keychain item.
        try? FileManager.default.removeItem(at: localFile)
        deleteKey(account: localAccount)
    }

    /// Re-wraps the same data key with a new passphrase, after checking the current one.
    ///
    /// Why not a fresh data key: re-encrypting would only lock out copies of the drive that are still in this
    /// drive's hands later, and every Mac that remembers the key would need the new passphrase too. The simpler,
    /// safe choice is to re-wrap and say plainly in the app that older copies of the drive (or of its
    /// "Offline Kit Private" folder) still open with the old passphrase.
    static func changePassphrase(from current: String, to passphrase: String) throws {
        guard let wrappedKeyURL, let wrapped = readWrapped() else { throw PassphraseError.notOnDrive }
        guard let key = currentKey() else { throw PassphraseError.locked }
        _ = try unwrap(wrapped, passphrase: current)
        try writeWrapped(wrap(key, passphrase: passphrase, id: wrapped.id), to: wrappedKeyURL)
    }

    /// The data key, if `passphrase` is right.
    private static func unwrap(_ wrapped: WrappedKey, passphrase: String) throws -> Data {
        let kek = try deriveKey(passphrase, salt: wrapped.salt, iterations: wrapped.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: wrapped.box),
              let raw = try? AES.GCM.open(box, using: kek, authenticating: Data(wrapped.id.utf8)) else {
            throw PassphraseError.wrongPassphrase
        }
        return raw
    }

    /// Turns the passphrase off: the details move back to this Mac and its Keychain, and leave the drive.
    static func removePassphrase() throws {
        guard let driveFolder, let wrappedKeyURL, let wrapped = readWrapped() else { return }
        guard let key = currentKey() else { throw PassphraseError.locked }
        let localFile = localFolder.appending(path: fileName)
        if FileManager.default.fileExists(atPath: localFile.path) { throw PassphraseError.thisMacHasItsOwn }
        try writeKey(key.withUnsafeBytes { Data($0) }, account: localAccount)
        let driveFile = driveFolder.appending(path: fileName)
        if let sealed = try? Data(contentsOf: driveFile) {
            let box = try AES.GCM.SealedBox(combined: sealed)
            try writeSealed(try AES.GCM.open(box, using: key), key: key, to: localFolder)
        }
        try FileManager.default.removeItem(at: wrappedKeyURL)
        try? FileManager.default.removeItem(at: driveFile)
        deleteKey(account: driveAccount(wrapped.id))
        sessionKey = nil
    }

    /// Opens the drive's details on this Mac. `remember` caches the key in this Mac's Keychain.
    static func unlock(_ passphrase: String, remember: Bool) throws {
        guard let wrapped = readWrapped() else { throw PassphraseError.damaged }
        let raw = try unwrap(wrapped, passphrase: passphrase)
        if remember { try writeKey(raw, account: driveAccount(wrapped.id)) } else { sessionKey = SymmetricKey(data: raw) }
    }

    /// Forgets the drive's key on this Mac. The details lock right away; the passphrase opens them again.
    static func forgetOnThisMac() {
        guard let wrapped = readWrapped() else { return }
        deleteKey(account: driveAccount(wrapped.id))
        sessionKey = nil
    }

    private static func wrap(_ key: SymmetricKey, passphrase: String, id: String) throws -> WrappedKey {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let kek = try deriveKey(passphrase, salt: salt, iterations: iterations)
        let raw = key.withUnsafeBytes { Data($0) }
        let box = try AES.GCM.seal(raw, using: kek, authenticating: Data(id.utf8)).combined!
        return WrappedKey(id: id, iterations: iterations, salt: salt, box: box)
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto.
    private static func deriveKey(_ passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        // The count comes from a key file that may sit on a drive: a damaged or made-up one must not crash the app.
        guard (1_000...10_000_000).contains(iterations) else { throw PassphraseError.damaged }
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw PassphraseError.damaged }
        defer { derived.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        return SymmetricKey(data: derived)
    }

    private static func readWrapped() -> WrappedKey? {
        guard let url = wrappedKeyURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WrappedKey.self, from: data)
    }

    private static func writeWrapped(_ wrapped: WrappedKey, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(wrapped).write(to: url, options: .atomic)
    }

    // MARK: Key

    private static let service = "com.joeychappel.offlinekit.private"
    private static let localAccount = "household-key"
    private static func driveAccount(_ id: String) -> String { "household-key-drive-\(id)" }

    /// Unlocked this run without "remember on this Mac".
    nonisolated(unsafe) private static var sessionKey: SymmetricKey?

    /// The key for the details in use now, if this device has it.
    static func currentKey() -> SymmetricKey? {
        if usesPassphrase {
            if let sessionKey { return sessionKey }
            guard let id = readWrapped()?.id, let data = readKey(account: driveAccount(id)) else { return nil }
            return SymmetricKey(data: data)
        }
        return readKey(account: localAccount).map { SymmetricKey(data: $0) }
    }

    private static func key(create: Bool) throws -> SymmetricKey {
        if let key = currentKey() { return key }
        // A passphrase store must never get a fresh key: that would make the drive's details unreadable.
        guard create, !usesPassphrase else { throw usesPassphrase ? PassphraseError.locked : CocoaError(.fileReadNoPermission) }
        let key = SymmetricKey(size: .bits256)
        try writeKey(key.withUnsafeBytes { Data($0) }, account: localAccount)
        return key
    }

    #if DEBUG
    /// Test runs (OFFLINEKIT_HOME) keep their keys in the test folder, so they never touch the real Keychain items.
    /// Each test home stands in for one Mac's Keychain.
    private static func testKeyFile(_ account: String) -> URL? {
        KitLocation.testHome?.appending(path: ".private/" + (account == localAccount ? "key" : account))
    }
    #endif

    private static func readKey(account: String) -> Data? {
        #if DEBUG
        if let file = testKeyFile(account) { return try? Data(contentsOf: file) }
        #endif
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeKey(_ data: Data, account: String) throws {
        #if DEBUG
        if let file = testKeyFile(account) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            return
        }
        #endif
        SecItemDelete(baseQuery(account) as CFDictionary)
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func deleteKey(account: String) {
        #if DEBUG
        if let file = testKeyFile(account) { try? FileManager.default.removeItem(at: file); return }
        #endif
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}
