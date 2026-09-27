import SwiftUI
import UIKit
import PassKit
import PhotosUI

// MARK: - Wallet Art Investigation

@MainActor
final class WalletArtInspector: ObservableObject {
    @Published private(set) var passes: [PKPass] = []
    @Published private(set) var status = "Not inspected"
    @Published private(set) var lastInspection = ""
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var advancedDiagnostics: [String] = []

    func inspect() {
        let library = PKPassLibrary()
        let found = library.passes()
        let secure = library.passes(of: .secureElement)
        let legacyPayment = library.passes(of: .payment)
        let remoteSecure = library.remoteSecureElementPasses

        passes = found
        lastInspection = Date().formatted(date: .abbreviated, time: .standard)
        diagnostics = [
            "Passes acessíveis por passes(): \(found.count)",
            "Secure Element acessível: \(secure.count)",
            "Payment pass (API legada): \(legacyPayment.count)",
            "Secure Element em dispositivos pareados: \(remoteSecure.count)"
        ]

        let exposedSecure = secure.count + legacyPayment.count
        if exposedSecure == 0 {
            status = "Nenhum cartão de pagamento/Secure Element foi exposto a este app pelo PassKit."
        } else {
            status = "\(exposedSecure) pass(es) de pagamento exposto(s) para inspeção de metadados."
        }
    }

    func runAdvancedDiagnostics() {
        let library = PKPassLibrary()
        let libraryAvailable = PKPassLibrary.isPassLibraryAvailable()
        let activationAvailable = library.isSecureElementPassActivationAvailable
        let backgroundAddPasses = library.authorizationStatus(for: .backgroundAddPasses)
        let found = library.passes()
        let secure = library.passes(of: .secureElement)
        let legacyPayment = library.passes(of: .payment)
        let remoteSecure = library.remoteSecureElementPasses

        advancedDiagnostics = [
            "Pass Library disponível: \(yesNo(libraryAvailable))",
            "Secure Element activation disponível: \(yesNo(activationAvailable))",
            "Autorização backgroundAddPasses: \(authorizationName(backgroundAddPasses))",
            "passes(): \(found.count)",
            "passes(.secureElement): \(secure.count)",
            "passes(.payment): \(legacyPayment.count)",
            "remoteSecureElementPasses: \(remoteSecure.count)",
            "Observação: zero passes aqui significa apenas zero passes acessíveis a este app pelas APIs públicas; não significa Wallet vazia."
        ]
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "SIM" : "NÃO"
    }

    private func authorizationName(_ status: PKPassLibrary.AuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    func clear() {
        passes = []
        status = "Not inspected"
        lastInspection = ""
        diagnostics = []
        advancedDiagnostics = []
    }
}

struct WalletArtLabTab: View {
    @StateObject private var inspector = WalletArtInspector()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var artwork: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Wallet Art Lab", systemImage: "creditcard.and.123")
                            .font(.title2.bold())

                        Text("Investigação focada somente na aparência da Carteira. Nenhuma credencial, número de cartão ou pagamento é alterado.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("1. Inspecionar a Wallet") {
                    Button {
                        inspector.inspect()
                    } label: {
                        Label("Inspecionar cartões/passes", systemImage: "magnifyingglass")
                    }

                    if !inspector.status.isEmpty {
                        Text(inspector.status)
                            .font(.caption)
                            .foregroundStyle(inspector.status.contains("No secure") ? .orange : .secondary)
                    }

                    if !inspector.lastInspection.isEmpty {
                        Text("Última leitura: \(inspector.lastInspection)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if !inspector.diagnostics.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(inspector.diagnostics, id: \.self) { line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if inspector.passes.isEmpty {
                        Text("Nenhum pass comum foi exposto pela API. Isso não significa que a Wallet esteja vazia; significa que este app não recebeu acesso a esses passes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(inspector.passes.enumerated()), id: \.offset) { _, pass in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(uiImage: pass.icon)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 7))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pass.localizedName)
                                            .font(.subheadline.bold())
                                        Text(pass.organizationName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }

                                Text("Tipo: \(passTypeName(pass))")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)

                                if pass.secureElementPass != nil || pass.passType == .secureElement {
                                    Label("Secure Element / payment pass", systemImage: "lock.shield")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section("1.1. Diagnóstico avançado — APIs públicas") {
                    Button {
                        inspector.runAdvancedDiagnostics()
                    } label: {
                        Label("Executar diagnóstico avançado", systemImage: "stethoscope")
                    }

                    Text("Este teste consulta somente APIs públicas/documentadas do PassKit. Ele não solicita, altera ou substitui cartões e não toca em credenciais de pagamento.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !inspector.advancedDiagnostics.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(inspector.advancedDiagnostics, id: \.self) { line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("2. Testar a arte que você quer usar") {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(artwork == nil ? "Escolher imagem da Fototeca" : "Trocar imagem", systemImage: "photo")
                    }

                    if let artwork {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preview da sua skin")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            ZStack(alignment: .bottomLeading) {
                                Image(uiImage: artwork)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 210)
                                    .clipped()

                                LinearGradient(
                                    colors: [.clear, .black.opacity(0.75)],
                                    startPoint: .center,
                                    endPoint: .bottom
                                )

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Cartão personalizado")
                                            .font(.headline.bold())
                                        Text("•••• 1738")
                                            .font(.caption.monospaced())
                                    }
                                    .foregroundStyle(.white)

                                    Spacer()

                                    Image(systemName: "creditcard.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                                .padding(16)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                }

                Section("3. Resultado desta investigação") {
                    Label("O teste confirmou o limite de acesso: este app não recebeu os cartões de pagamento reais pela API pública do PassKit.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("A próxima etapa é investigar apenas interfaces públicas e entitlements documentados. Em paralelo, o editor de skins continua funcionando como preview sem tocar em credenciais, NFC ou pagamentos.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(role: .destructive) {
                        inspector.clear()
                        artwork = nil
                        selectedPhoto = nil
                    } label: {
                        Label("Limpar investigação", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Wallet Art Lab")
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            artwork = image
                            selectedPhoto = nil
                        }
                    }
                }
            }
        }
    }

    private func passTypeName(_ pass: PKPass) -> String {
        switch pass.passType {
        case .secureElement: return "secureElement"
        case .barcode: return "barcode"
        case .payment: return "payment (deprecated)"
        default: return "other/unknown"
        }
    }
}
