// jarvis-keyhelper: keeps Jarvis's saved keys and releases them after Touch ID.
//
// Why a separate program: macOS ties Keychain approval to the exact binary unless the app has an Apple
// team signature. Jarvis is rebuilt often and has none, so every rebuild used to bring back the
// "enter your login keychain password" prompt. This helper is built once and then left alone, so its
// approval lasts. Jarvis asks it for keys; it checks who is asking, asks for Touch ID, and answers.
//
// KEEP THIS FILE SMALL AND STABLE. Reinstalling a changed helper makes macOS ask for the keychain
// password again for every saved key.
//
// Protocol: `jarvis-keyhelper <command>`, a JSON object on stdin, a JSON object on stdout.
//   version                                  -> {"ok":true,"version":"1"}
//   status  {"accounts":[…]}                 -> which accounts are in the vault / still in the old store; policy
//   get     {"accounts":[…]}                 -> values, after Touch ID when the policy requires it
//   import  {"accounts":[…]}                 -> moves old-store items into the vault (macOS asks for the keychain
//                                               password once per item), then returns all values like `get`
//   set     {"account":…,"value":…}          -> stores a value
//   delete  {"account":…}                    -> removes a value
//   policy  {"require":"touchid"|"none"}     -> whether `get` needs Touch ID; turning it off needs Touch ID
// Secrets travel only over the pipes to the parent process, never in arguments.

import Foundation
import LocalAuthentication
import Security

let helperVersion = "1"
let vaultService = "com.samarth.jarvis.vault"
let legacyService = "com.samarth.jarvis"
let policyAccount = "__policy"
let trustedParentIdentifier = "com.samarth.jarvis"

func reply(_ object: [String: Any], exitCode: Int32 = 0) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
    FileHandle.standardOutput.write(data)
    exit(exitCode)
}

func fail(_ message: String) -> Never { reply(["ok": false, "error": message], exitCode: 1) }

// MARK: Who is asking

func signing(of code: SecStaticCode) -> (identifier: String?, leaf: Data?) {
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return (nil, nil) }
    let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate]
    return (dict[kSecCodeInfoIdentifier as String] as? String, certs?.first.map { SecCertificateCopyData($0) as Data })
}

/// The parent process must be a validly signed Jarvis, signed with the same certificate as this helper.
func parentIsJarvis() -> (ok: Bool, why: String) {
    var parent: SecCode?
    let attributes = [kSecGuestAttributePid as String: getppid()] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess, let parent else { return (false, "cannot identify the calling process") }
    guard SecCodeCheckValidity(parent, [], nil) == errSecSuccess else { return (false, "the calling process is not validly signed") }
    var parentStatic: SecStaticCode?
    guard SecCodeCopyStaticCode(parent, [], &parentStatic) == errSecSuccess, let parentStatic else { return (false, "cannot read the caller's signature") }
    let caller = signing(of: parentStatic)
    guard caller.identifier == trustedParentIdentifier else { return (false, "caller is \(caller.identifier ?? "unsigned"), not Jarvis") }

    var me: SecCode?
    var meStatic: SecStaticCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic else {
        return (false, "cannot read my own signature")
    }
    let mine = signing(of: meStatic)
    // Signed with a certificate: the caller must carry the same one. (An ad-hoc helper has none to compare.)
    if let myLeaf = mine.leaf { guard caller.leaf == myLeaf else { return (false, "caller is signed with a different certificate") } }
    return (true, "")
}

// MARK: Keychain

func query(_ service: String, _ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
}

/// True when the item exists. Asks only for attributes, so macOS never prompts.
func exists(_ service: String, _ account: String) -> Bool {
    var q = query(service, account)
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
}

func read(_ service: String, _ account: String, allowPrompt: Bool) -> (value: String?, status: OSStatus) {
    SecKeychainSetUserInteractionAllowed(allowPrompt)
    defer { SecKeychainSetUserInteractionAllowed(true) }
    var q = query(service, account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return (nil, status) }
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed.isEmpty ? nil : trimmed, status)
}

@discardableResult
func write(_ account: String, _ value: String) -> OSStatus {
    SecItemDelete(query(vaultService, account) as CFDictionary)
    var add = query(vaultService, account)
    add[kSecValueData as String] = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    add[kSecAttrLabel as String] = "Jarvis vault: \(account)"
    return SecItemAdd(add as CFDictionary, nil)
}

// MARK: Touch ID

func requiresTouchID() -> Bool { read(vaultService, policyAccount, allowPrompt: false).value != "none" }

/// Touch ID (or Apple Watch), with the account password as the system's own fallback.
func authenticate(_ reason: String) -> (ok: Bool, why: String) {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return (false, error?.localizedDescription ?? "authentication is not available") }
    let done = DispatchSemaphore(value: 0)
    var ok = false
    var why = ""
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, err in
        ok = success
        why = err?.localizedDescription ?? ""
        done.signal()
    }
    done.wait()
    return (ok, why)
}

// MARK: Commands

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: jarvis-keyhelper <version|status|get|import|set|delete|policy>") }
let command = arguments[1]
if command == "version" { reply(["ok": true, "version": helperVersion]) }

let trust = parentIsJarvis()
guard trust.ok else { fail("refused: \(trust.why)") }

let input = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
let accounts = (input["accounts"] as? [String] ?? []).filter { !$0.isEmpty && $0 != policyAccount }

func values(for accounts: [String]) -> [String: Any] {
    var out: [String: Any] = [:]
    var locked: [String] = []
    for a in accounts {
        let r = read(vaultService, a, allowPrompt: false)
        if let v = r.value { out[a] = v }
        else if r.status != errSecItemNotFound { locked.append(a) }      // there, but macOS will not hand it over silently
    }
    return ["ok": true, "values": out, "needs_approval": locked]
}

switch command {
case "status":
    reply(["ok": true, "version": helperVersion,
           "vault": accounts.filter { exists(vaultService, $0) },
           "legacy": accounts.filter { exists(legacyService, $0) },
           "policy": requiresTouchID() ? "touchid" : "none"])

case "get":
    if requiresTouchID() {
        let auth = authenticate("unlock Jarvis's saved keys")
        guard auth.ok else { reply(["ok": false, "error": "not unlocked: \(auth.why)", "locked": true], exitCode: 2) }
    }
    reply(values(for: accounts))

case "import":
    if requiresTouchID() {
        let auth = authenticate("move Jarvis's saved keys into its vault")
        guard auth.ok else { reply(["ok": false, "error": "not unlocked: \(auth.why)", "locked": true], exitCode: 2) }
    }
    var imported: [String] = [], denied: [String] = []
    for a in accounts where !exists(vaultService, a) && exists(legacyService, a) {
        // macOS asks for the login keychain password here: the old item belongs to an older Jarvis build.
        let old = read(legacyService, a, allowPrompt: true)
        if let v = old.value, write(a, v) == errSecSuccess { imported.append(a) } else { denied.append(a) }
    }
    var result = values(for: accounts)
    result["imported"] = imported
    result["denied"] = denied
    reply(result)

case "set":
    guard let account = input["account"] as? String, !account.isEmpty, account != policyAccount,
          let value = input["value"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("set needs account and value") }
    let status = write(account, value)
    guard status == errSecSuccess else { fail("keychain error \(status)") }
    reply(["ok": true])

case "delete":
    guard let account = input["account"] as? String, !account.isEmpty, account != policyAccount else { fail("delete needs account") }
    SecItemDelete(query(vaultService, account) as CFDictionary)
    reply(["ok": true])

case "policy":
    guard let require = input["require"] as? String, ["touchid", "none"].contains(require) else { fail("policy needs require: touchid or none") }
    if require == "none", requiresTouchID() {
        let auth = authenticate("turn off Touch ID for Jarvis's saved keys")
        guard auth.ok else { reply(["ok": false, "error": "not changed: \(auth.why)", "locked": true], exitCode: 2) }
    }
    guard write(policyAccount, require) == errSecSuccess else { fail("could not save the policy") }
    reply(["ok": true, "policy": require])

default:
    fail("unknown command \(command)")
}
