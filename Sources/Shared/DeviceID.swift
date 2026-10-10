import Foundation
import UIKit
import Security

/// 设备标识
///
/// 首次运行生成一个 UUID，存进钥匙串。钥匙串在 App 卸载重装后仍在，
/// 所以同一个手机重装也还是同一台设备，服务端那边不会误判成「换机」。
enum DeviceID {

    private static let service = "com.anran.ime.device"
    private static let account = "machine-id"

    private static var cached: String?

    static var current: String {
        if let cached { return cached }
        if let v = readKeychain(), !v.isEmpty {
            cached = v
            return v
        }
        // 钥匙串拿不到就退回 identifierForVendor，再不行才用随机 UUID
        let seed = UIDevice.current.identifierForVendor?.uuidString
            ?? UUID().uuidString
        writeKeychain(seed)
        cached = seed
        return seed
    }

    // MARK: - 钥匙串

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKeychain() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) {
        let data = Data(value.utf8)
        SecItemDelete(query() as CFDictionary)
        var q = query()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}