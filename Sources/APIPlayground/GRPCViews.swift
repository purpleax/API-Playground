import APIEngine
import SwiftUI

/// The strip under a gRPC request's address: which method it calls, and where the list of
/// methods comes from.
struct GRPCMethodBar: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID

    private var request: RequestItem? { model.request(requestID) }

    var body: some View {
        let schema = model.grpcSchema(requestID)
        let chosen = request?.grpcMethod ?? ""
        let method = schema?.method(chosen)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Menu {
                    if let schema {
                        ForEach(schema.services) { service in
                            Section(service.fullName) {
                                ForEach(service.methods) { method in
                                    Button("\(method.name)  ·  \(method.kind)") { model.setGRPCMethod(requestID, to: method) }
                                }
                            }
                        }
                    } else {
                        Text("Load the server's methods first")
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "function")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(chosen.isEmpty ? "Choose a method" : chosen)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(chosen.isEmpty ? Theme.textSecondary : Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(Theme.stroke))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("The method this request calls")

                if let method { Chip(text: method.kind, color: Theme.violet, mono: false) }
                Spacer(minLength: 4)
                if model.grpcLoading.contains(requestID) {
                    ProgressView().controlSize(.small)
                }
                Button(schema == nil ? "Load Methods" : "Reload") {
                    Task { await model.loadGRPCSchema(requestID) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.grpcLoading.contains(requestID))
                .help("Ask the server to describe its services (server reflection)")
                IconButton(systemImage: "doc.badge.arrow.up", help: "Load the services from a descriptor set file, for a server without reflection") {
                    model.chooseGRPCDescriptor(requestID)
                }
            }

            if let note = model.grpcNotes[requestID] {
                Text(note.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(note.isError ? Theme.danger : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if schema == nil {
                Text("Load the server's methods to choose one. They are remembered for this address.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            } else if !chosen.isEmpty, method == nil {
                Text("The server no longer describes “\(chosen)”. Choose another method, or reload.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// The message a gRPC request sends, written as JSON.
struct GRPCMessageEditor: View {
    @Environment(AppModel.self) private var model
    let requestID: UUID

    private var text: Binding<String> {
        Binding(
            get: {
                if case .raw(let text, _) = model.request(requestID)?.body { return text }
                return ""
            },
            set: { new in
                guard var request = model.request(requestID) else { return }
                request.body = .raw(text: new, contentType: "application/json")
                model.update(request)
            }
        )
    }

    var body: some View {
        let schema = model.grpcSchema(requestID)
        let method = schema?.method(model.request(requestID)?.grpcMethod ?? "")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let method {
                    Text(method.inputType)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if method.clientStreaming {
                        Text("Write a list in [ ] to send several messages.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text("The message, as JSON")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Fill In an Example") { model.fillGRPCExample(requestID) }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(method == nil)
                    .help("Replace the message with one that has every field, ready to fill in")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            CodeTextView(text: text, syntax: .json)
        }
    }
}
