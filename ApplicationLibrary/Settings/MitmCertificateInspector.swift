import Library
import Security
import SwiftUI

struct MitmCertificateStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case missing
        case notTrusted
        case trusted
        case invalid
    }

    var kind: Kind
    var url: URL?

    static let missing = MitmCertificateStatus(kind: .missing, url: nil)

    var title: LocalizedStringKey {
        switch kind {
        case .missing: return "Not Created"
        case .notTrusted: return "Not Trusted"
        case .trusted: return "Trusted"
        case .invalid: return "Invalid"
        }
    }

    var systemImage: String {
        switch kind {
        case .missing: "circle.dashed"
        case .notTrusted: "exclamationmark.shield"
        case .trusted: "checkmark.shield.fill"
        case .invalid: "xmark.shield"
        }
    }

    var tint: Color {
        switch kind {
        case .missing: .secondary
        case .notTrusted: .orange
        case .trusted: .green
        case .invalid: .red
        }
    }

    var footer: LocalizedStringKey {
        switch kind {
        case .missing:
            return "Create and install the local root CA before using MITM HTTPS rewriting."
        case .notTrusted:
            return "After opening the certificate, install the downloaded profile in iOS Settings > General > VPN & Device Management, then enable full trust in Settings > General > About > Certificate Trust Settings."
        case .trusted:
            return "The local MITM root CA is trusted by iOS. HTTPS rewriting can work for profiles that enable MITM."
        case .invalid:
            return "The certificate file is invalid. Install again to create a fresh certificate."
        }
    }
}

enum MitmCertificateInspector {
    static func status(createIfNeeded: Bool) throws -> MitmCertificateStatus {
        let url = try certificateURL(createIfNeeded: createIfNeeded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard FileManager.default.fileExists(atPath: FilePath.mitmPrivateKeyFile.path) else {
            return MitmCertificateStatus(kind: .invalid, url: url)
        }

        let trusted: Bool
        do {
            trusted = try isTrustedForHTTPS()
        } catch {
            return MitmCertificateStatus(kind: .invalid, url: url)
        }
        return MitmCertificateStatus(
            kind: trusted ? .trusted : .notTrusted,
            url: url
        )
    }

    private static func certificateURL(createIfNeeded: Bool) throws -> URL {
        if createIfNeeded {
            LibmihomoBridge.setHomeDir(FilePath.workingDirectory.path)
            return try LibmihomoBridge.ensureMitmCertificate()
        }
        return FilePath.mitmCertificateFile
    }

    private static func certificates(fromPEM data: Data) -> [SecCertificate] {
        guard let pem = String(data: data, encoding: .ascii) else {
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else { return [] }
            return [certificate]
        }

        var certificates: [SecCertificate] = []
        var searchStart = pem.startIndex
        while let begin = pem.range(of: "-----BEGIN CERTIFICATE-----", range: searchStart..<pem.endIndex),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex) {
            let base64 = pem[begin.upperBound..<end.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            if let der = Data(base64Encoded: base64),
               let certificate = SecCertificateCreateWithData(nil, der as CFData) {
                certificates.append(certificate)
            }
            searchStart = end.upperBound
        }
        return certificates
    }

    private static func isTrustedForHTTPS() throws -> Bool {
        let probeHost = "mitm.mihomo"
        let chain = certificates(fromPEM: try LibmihomoBridge.mitmTrustProbePEM(host: probeHost))
        guard !chain.isEmpty else { return false }

        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            chain as CFArray,
            SecPolicyCreateSSL(true, probeHost as CFString),
            &trust
        )
        guard status == errSecSuccess, let trust else {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
