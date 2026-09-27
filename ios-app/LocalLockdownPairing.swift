import Foundation
import AirliftFFI
import Darwin

/// iOS 26.x fallback pairing path.
///
/// The normal RPPairing flow advertises a Mac-like host and waits for the device
/// to initiate pairing. On iOS 26.x that device-initiated Wi-Fi onboarding is
/// not available, so this controller tests the older Lockdown Pair exchange
/// directly through LocalDevVPN. It uses the existing idevice-ffi symbols that
/// are already linked into AirliftFFI; no new Rust ABI is introduced here.
///
/// This is pairing/diagnostics only. It does not modify the exploit path.
@MainActor
final class LocalLockdownPairing: ObservableObject {
    static let shared = LocalLockdownPairing()

    @Published private(set) var running = false
    @Published private(set) var status = "idle"
    @Published private(set) var log: [String] = []
    @Published private(set) var pairingFilePath: String?

    private static let hostIDKey = "aircardLockdownHostID"
    private static let systemBUIDKey = "aircardLockdownSystemBUID"

    private init() {}

    nonisolated static var hostID: String {
        if let value = UserDefaults.standard.string(forKey: hostIDKey), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: hostIDKey)
        return value
    }

    nonisolated static var systemBUID: String {
        if let value = UserDefaults.standard.string(forKey: systemBUIDKey), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: systemBUIDKey)
        return value
    }

    func start(deviceIP: String) {
        guard !running else { return }

        let ip = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            status = "❌ Device IP is empty."
            return
        }

        running = true
        status = "Connecting to Lockdown…"
        log.removeAll()
        pairingFilePath = nil

        Task.detached { [weak self] in
            do {
                let result = try Self.perform(deviceIP: ip)
                await MainActor.run {
                    self?.pairingFilePath = result.path
                    self?.status = "✅ Lockdown pairing completed ((result.bytes) bytes)."
                    self?.log.append("Pair record saved: (result.path)")
                    self?.running = false
                }
            } catch {
                await MainActor.run {
                    self?.status = "❌ (error.localizedDescription)"
                    self?.log.append("Failure: (error)")
                    self?.running = false
                }
            }
        }
    }

    private struct PairResult {
        let path: String
        let bytes: Int
    }

    private enum PairError: LocalizedError {
        case ffi(String)
        case noSocket
        case noClient
        case noPairingFile
        case emptyRecord

        var errorDescription: String? {
            switch self {
            case .ffi(let message): return message
            case .noSocket: return "Lockdown socket was not created."
            case .noClient: return "Lockdown client was not created."
            case .noPairingFile: return "Lockdown did not return a pairing record."
            case .emptyRecord: return "Lockdown returned an empty pairing record."
            }
        }
    }

    nonisolated private static func ffiMessage(_ error: UnsafeMutablePointer<IdeviceFfiError>?,
                                   fallback: String) -> String? {
        guard let error else { return nil }
        let code = error.pointee.code
        let sub = error.pointee.sub_code
        let message = error.pointee.message.flatMap { String(validatingUTF8: $0) } ?? fallback
        idevice_error_free(error)
        return "idevice FFI (code)/(sub): (message)"
    }

    nonisolated private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?,
                              fallback: String) throws {
        if let message = ffiMessage(error, fallback: fallback) {
            throw PairError.ffi(message)
        }
    }

    nonisolated private static func perform(deviceIP: String) throws -> PairResult {
        let hosts = [deviceIP, "127.0.0.1"]
        var lastError: Error?

        for host in hosts {
            do {
                return try pair(host: host)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? PairError.ffi("No Lockdown address could be reached.")
    }

    nonisolated private static func pair(host: String) throws -> PairResult {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(62078).bigEndian

        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw PairError.ffi("Invalid IPv4 address: (host)")
        }

        var device: UnsafeMutablePointer<IdeviceHandle>?
        let connectError = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Self.hostName.withCString { label in
                    idevice_new_tcp_socket(
                        sockaddrPtr,
                        UInt32(MemoryLayout<sockaddr_in>.stride),
                        label,
                        &device
                    )
                }
            }
        }

        if let message = ffiMessage(
            connectError,
            fallback: "Couldn't reach Lockdown at (host):62078"
        ) {
            throw PairError.ffi(message)
        }

        guard let device else {
            throw PairError.noSocket
        }

        // lockdownd_new consumes the device socket.
        var client: UnsafeMutablePointer<LockdowndClientHandle>?
        try check(
            lockdownd_new(device, &client),
            fallback: "lockdownd_new failed"
        )

        guard let client else {
            throw PairError.noClient
        }
        defer { lockdownd_client_free(client) }

        var pairingFile: UnsafeMutablePointer<IdevicePairingFile>?
        try Self.hostID.withCString { hostID in
            try Self.systemBUID.withCString { systemBUID in
                try Self.hostName.withCString { hostName in
                    try check(
                        lockdownd_pair(
                            client,
                            hostID,
                            systemBUID,
                            hostName,
                            &pairingFile
                        ),
                        fallback: "lockdownd_pair failed"
                    )
                }
            }
        }

        guard let pairingFile else {
            throw PairError.noPairingFile
        }
        defer { idevice_pairing_file_free(pairingFile) }

        var bytesPtr: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        try check(
            idevice_pairing_file_serialize(pairingFile, &bytesPtr, &length),
            fallback: "idevice_pairing_file_serialize failed"
        )

        guard let bytesPtr, length > 0 else {
            throw PairError.emptyRecord
        }

        let data = Data(bytes: bytesPtr, count: Int(length))
        idevice_data_free(bytesPtr, UInt(length))

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("aircard_lockdown_pairing.plist")
        try data.write(to: url, options: .atomic)

        return PairResult(path: url.path, bytes: data.count)
    }

    nonisolated private static let hostName = "AirCard-iOS"
}
