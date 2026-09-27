import Foundation
import AVFAudio
import CoreLocation
import Network

// MARK: - Keep-alive (audio + optional location)

/// Keeps the app running in the background while the user approves the pairing
/// PIN in Settings → Developer Mode.
@MainActor
final class KeepAlive: NSObject {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioRunning = false

    func startAudio() {
        guard !audioRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if player.engine == nil {
                engine.attach(player)
            }
            let format = engine.outputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                audioRunning = true
                return
            }

            engine.connect(player, to: engine.mainMixerNode, format: format)

            let frames = max(1024, AVAudioFrameCount(format.sampleRate))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                audioRunning = true
                return
            }
            buffer.frameLength = frames
            if let channelData = buffer.floatChannelData {
                for ch in 0..<Int(format.channelCount) {
                    memset(channelData[ch], 0, Int(frames) * MemoryLayout<Float>.size)
                }
            }

            if !engine.isRunning {
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioRunning = true
        } catch {
            audioRunning = false
        }
    }

    func stopAudio() {
        guard audioRunning else { return }
        audioRunning = false
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        if player.engine != nil {
            engine.detach(player)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func stopAll() {
        stopAudio()
    }
}

// MARK: - Local Network permission

/// Triggers the Local Network permission dialog by briefly advertising and
/// browsing a throwaway Bonjour service. Non-blocking with short timeout
/// so it never hangs the pairing flow.
@MainActor
final class LocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?

    // Must match an entry in Info.plist NSBonjourServices.
    private let probeType = "_aircardprobe._tcp"

    func request(timeout: TimeInterval = 1.5) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont

            let params = NWParameters.tcp
            params.includePeerToPeer = true

            let listener = try? NWListener(using: params)
            listener?.service = NWListener.Service(name: "AirCardProbe", type: probeType)
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: params)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.browser = browser

            listener?.start(queue: .main)
            browser.start(queue: .main)

            // Short timeout — if dialog was already accepted or dismissed, proceed anyway.
            // NetService.publish() in PairingController will also trigger permission if needed.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(true) }
            }
        }
    }

    private func finish(_ authorized: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: authorized)
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
    }
}


// MARK: - LocalDevVPN TCP diagnostic

/// Tests whether the app can open a TCP connection to the device endpoint
/// through LocalDevVPN without invoking Lockdown or pairing.
/// This is diagnostic-only and does not touch the exploit path.
@MainActor
final class LocalVPNTCPProbe: ObservableObject {
    static let shared = LocalVPNTCPProbe()

    @Published private(set) var running = false
    @Published private(set) var status = "idle"
    @Published private(set) var log: [String] = []

    private var connection: NWConnection?
    private var timeoutWork: DispatchWorkItem?

    private init() {}

    func test(host: String, port: UInt16 = 62078) {
        guard !running else { return }

        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "❌ Device IP is empty."
            return
        }

        cancelConnection()
        running = true
        status = "Connecting to \(trimmed):\(port)…"
        log.removeAll()

        let endpoint = NWEndpoint.Host(trimmed)
        let connection = NWConnection(host: endpoint, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.running = false
                    self.status = "✅ TCP connection established to \(trimmed):\(port)."
                    self.log.append("NWConnection state: ready")
                    self.log.append("LocalDevVPN transport is reachable from AirCard.")
                    self.cancelConnection()

                case .failed(let error):
                    self.running = false
                    self.status = "❌ TCP connection failed."
                    self.log.append("NWConnection state: failed")
                    self.log.append("Error: \(error)")
                    self.cancelConnection()

                case .waiting(let error):
                    self.log.append("NWConnection waiting: \(error)")

                case .preparing:
                    self.log.append("NWConnection preparing…")

                case .setup:
                    break

                case .cancelled:
                    break

                @unknown default:
                    self.log.append("NWConnection state: unknown")
                }
            }
        }

        connection.start(queue: .main)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.status = "❌ TCP connection timed out."
            self.log.append("No TCP connection to \(trimmed):\(port) within 4 seconds.")
            self.cancelConnection()
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    func cancel() {
        running = false
        status = "Cancelled"
        cancelConnection()
    }

    private func cancelConnection() {
        timeoutWork?.cancel()
        timeoutWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }
}
