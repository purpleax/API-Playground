import APIEngine
import AppKit
import SwiftUI

/// The field above a JSON body that narrows it down with a JSONPath or jq expression.
/// The expression is saved with the request.
struct ResponseFilterBar: View {
    @Binding var filter: String
    /// What is wrong with the expression, when it could not be run.
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(filter.isEmpty ? Theme.textTertiary : Theme.accent)
                TextField("Filter the body: $.items[*].name  or  .items[] | select(.price > 10)", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .autocorrectionDisabled()
                if !filter.isEmpty {
                    Chip(text: JSONQuery.dialect(of: filter) == .jsonPath ? "JSONPath" : "jq", color: Theme.textSecondary, mono: false)
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the filter and show the whole body")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius).strokeBorder(problem == nil ? Theme.stroke : Theme.warning.opacity(0.6)))
            .help("Show only part of a JSON body. Start with $ for JSONPath, or with a dot for jq. The filter is saved with the request.")
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The caller's quota, read from the response's rate-limit headers.
struct RateLimitGauge: View {
    let limit: RateLimit

    private var color: Color {
        guard let fraction = limit.fractionRemaining else { return limit.remaining == 0 ? Theme.danger : Theme.info }
        return fraction <= 0.1 ? Theme.danger : fraction <= 0.3 ? Theme.warning : Theme.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Rate limit").sectionTitle()
                Spacer()
                Text(summary)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            if let fraction = limit.fractionRemaining {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.raised)
                        Capsule()
                            .fill(color)
                            .shadow(color: color.opacity(0.5), radius: 4)
                            .frame(width: max(fraction > 0 ? 6 : 0, geometry.size.width * fraction))
                    }
                }
                .frame(height: 8)
                .accessibilityLabel("\(Int(fraction * 100)) percent of the quota remaining")
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
    }

    private var summary: String {
        switch (limit.remaining, limit.limit) {
        case (let remaining?, let total?): return "\(remaining) of \(total) left"
        case (let remaining?, nil): return "\(remaining) left"
        case (nil, let total?): return "Limit \(total)"
        default: return "Wait before retrying"
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let reset = limit.reset {
            let seconds = reset.timeIntervalSinceNow
            parts.append(seconds > 0
                ? "Refills in \(Self.span(seconds)), at \(reset.formatted(date: .omitted, time: .standard))"
                : "Refilled at \(reset.formatted(date: .omitted, time: .standard))")
        }
        if let retry = limit.retryAfter {
            parts.append("The server asked for a wait of \(Self.span(retry)) before the next request")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ") + "."
    }

    static func span(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 90 { return "\(whole) s" }
        if whole < 5400 { return "\(whole / 60) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}

/// The JSON Web Tokens seen in a request and its response, decoded for reading.
struct JWTList: View {
    let tokens: [JWT.Found]
    var redactor: Redactor?
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tokens.count == 1 ? "JSON Web Token" : "JSON Web Tokens").sectionTitle()
            ForEach(tokens) { found in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if open.contains(found.id) { open.remove(found.id) } else { open.insert(found.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: open.contains(found.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 10)
                            Text(found.source)
                                .font(.system(size: 12.5, weight: .semibold))
                            if let algorithm = found.jwt.algorithm { Chip(text: algorithm) }
                            Spacer()
                            expiry(found.jwt)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show what this token says. Its signature is not checked.")
                    if open.contains(found.id) {
                        claims(found.jwt)
                    }
                }
                .padding(10)
                .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
        }
    }

    @ViewBuilder
    private func expiry(_ jwt: DecodedJWT) -> some View {
        if let expires = jwt.expires {
            let remaining = expires.timeIntervalSinceNow
            if remaining <= 0 {
                Chip(text: "Expired \(expires.formatted(date: .abbreviated, time: .shortened))", color: Theme.danger, mono: false)
            } else {
                Chip(text: "Expires in \(RateLimitGauge.span(remaining))", color: remaining < 300 ? Theme.warning : Theme.success, mono: false)
            }
        } else {
            Chip(text: "No expiry", color: Theme.textSecondary, mono: false)
        }
    }

    private func claims(_ jwt: DecodedJWT) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let dates: [(String, Date?)] = [("Issued", jwt.issuedAt), ("Not valid before", jwt.notBefore), ("Expires", jwt.expires)]
            ForEach(dates.filter { $0.1 != nil }, id: \.0) { label, date in
                HStack(spacing: 8) {
                    Text(label).foregroundStyle(Theme.textSecondary).frame(width: 120, alignment: .leading)
                    Text(date!.formatted(date: .abbreviated, time: .standard))
                }
                .font(.system(size: 12))
            }
            Text("Header").sectionTitle()
            code(jwt.header)
            Text("Claims").sectionTitle()
            code(jwt.payload)
        }
        .padding(.leading, 18)
    }

    private func code(_ text: String) -> some View {
        Text(redactor?.redact(text) ?? text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
    }
}

/// The TLS connection a response came over, and the certificates the server presented.
struct TLSView: View {
    let tls: TLSInfo
    @State private var copied: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection").sectionTitle()
                HStack(spacing: 8) {
                    if let version = tls.protocolVersion { Chip(text: version, color: Theme.info) }
                    if let cipher = tls.cipher { Chip(text: cipher) }
                    if tls.verified {
                        Label("Certificate checked", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.success)
                    } else {
                        Label("Certificate not checked", systemImage: "exclamationmark.shield.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                            .help("This request was sent with certificate checking switched off.")
                    }
                }
                if let client = tls.clientCertificate {
                    Label("Client certificate offered: \((client as NSString).lastPathComponent)", systemImage: "person.badge.key.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .help(client)
                }
            }

            Text(tls.certificates.count == 1 ? "Certificate" : "Certificate chain").sectionTitle()
            if tls.certificates.isEmpty {
                Text("The connection was reused, or the server's certificates were not reported.")
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(tls.certificates) { certificate in
                card(certificate, position: certificate.id, of: tls.certificates.count)
            }
        }
    }

    private func role(_ certificate: TLSCertificate, position: Int, of count: Int) -> String {
        if position == 0 { return "Server" }
        if certificate.isSelfSigned { return "Root" }
        return "Intermediate"
    }

    private func card(_ certificate: TLSCertificate, position: Int, of count: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: position == 0 ? "lock.fill" : "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(certificate.commonName)
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)
                Chip(text: role(certificate, position: position, of: count), color: Theme.textSecondary, mono: false)
                if position == 0, certificate.isSelfSigned {
                    Chip(text: "Self-signed", color: Theme.warning, mono: false)
                }
                Spacer()
                validity(certificate)
            }
            row("Issued by", certificate.issuerName)
            row("Subject", certificate.subject)
            if let from = certificate.notBefore, let until = certificate.notAfter {
                row("Valid", "\(from.formatted(date: .abbreviated, time: .omitted)) to \(until.formatted(date: .abbreviated, time: .omitted))")
            }
            if !certificate.alternativeNames.isEmpty {
                row("Names", certificate.alternativeNames.joined(separator: ", "))
            }
            if let key = certificate.publicKey { row("Public key", key) }
            if let algorithm = certificate.signatureAlgorithm { row("Signature", algorithm) }
            if let serial = certificate.serialNumber { row("Serial number", serial) }
            if let pem = certificate.pem {
                Button(copied == certificate.id ? "Copied" : "Copy Certificate") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pem, forType: .string)
                    copied = certificate.id
                }
                .buttonStyle(GhostButtonStyle())
                .help("Copy this certificate as PEM text")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.smallRadius))
    }

    @ViewBuilder
    private func validity(_ certificate: TLSCertificate) -> some View {
        if let until = certificate.notAfter {
            let days = Int(until.timeIntervalSinceNow / 86400)
            if until <= Date() {
                Chip(text: "Expired", color: Theme.danger, mono: false)
            } else if let from = certificate.notBefore, from > Date() {
                Chip(text: "Not valid yet", color: Theme.danger, mono: false)
            } else if days < 30 {
                Chip(text: days < 1 ? "Expires today" : "Expires in \(days) day\(days == 1 ? "" : "s")", color: Theme.warning, mono: false)
            } else {
                Chip(text: "Valid for \(days) days", color: Theme.success, mono: false)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}
