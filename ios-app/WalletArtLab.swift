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

    func inspect() {
        let library = PKPassLibrary()
        let found = library.passes()
        passes = found
        lastInspection = Date().formatted(date: .abbreviated, time: .standard)

        let secure = found.filter { $0.secureElementPass != nil || $0.passType == .secureElement }
        if secure.isEmpty {
            status = "No secure-element/payment passes were exposed to this app."
        } else {
            status = "(secure.count) secure-element/payment pass(es) exposed for metadata inspection."
        }
    }

    func clear() {
        passes = []
        status = "Not inspected"
        lastInspection = ""
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
                        Text("Última leitura: (inspector.lastInspection)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if inspector.passes.isEmpty {
                        Text("Nenhum pass exposto pela API foi listado ainda.")
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

                                Text("Tipo: (passTypeName(pass))")
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
                    Label("A API pública permite ler/representar passes, mas não oferece um setter para substituir a arte de um payment/secure-element pass existente.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Por isso estamos separando o problema em duas partes: descobrir exatamente o que o iOS expõe sobre o cartão real e, paralelamente, construir o editor de skins que você quer.")
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
            .photosPicker(
                isPresented: .constant(false),
                selection: .constant(nil as PhotosPickerItem?),
                matching: .images
            )
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
        case .payment: return "payment"
        case .boardingPass: return "boardingPass"
        case .coupon: return "coupon"
        case .storeCard: return "storeCard"
        case .generic: return "generic"
        @unknown default: return "unknown"
        }
    }
}
