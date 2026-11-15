import Foundation

extension SAPSigner {
    private static let setupUA =
        "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5"

    /// Establish protocol-200 state using Apple's certificate and two-round setup service.
    static func connect() async throws -> SAPSigner {
        func exchange(url: String, payload: Data? = nil, key: String) async throws -> Data {
            guard let endpoint = URL(string: url) else {
                throw SAPError.invalidInput("Bad SAP setup URL")
            }
            var req = URLRequest(url: endpoint)
            req.setValue(setupUA, forHTTPHeaderField: "User-Agent")
            if let payload {
                req.httpMethod = "POST"
                req.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
                req.httpBody = try PropertyListSerialization.data(
                    fromPropertyList: ["sign-sap-setup-buffer": payload],
                    format: .xml,
                    options: 0
                )
            } else {
                req.httpMethod = "GET"
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let value = plist[key] as? Data, !value.isEmpty, value.count <= 1 << 20
            else {
                throw SAPError.invalidInput("SAP setup service returned an invalid response (HTTP \(status))")
            }
            return value
        }

        let certificate = try await exchange(
            url: "https://s.mzstatic.com/sap/setupCert.plist",
            key: "sign-sap-setup-cert"
        )
        let handshake = try SAPHandshake(certificate: certificate)
        let reply = try await exchange(
            url: "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy",
            payload: handshake.request,
            key: "sign-sap-setup-buffer"
        )
        return try SAPSigner(session: handshake.complete(reply))
    }
}
