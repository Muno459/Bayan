// EXAMPLE / TEMPLATE — committed to source control as a reference.
//
// To bring up a fresh checkout:
//   1. Copy this file to `Secrets.swift` in the SAME directory.
//   2. Paste in your QF client credentials from
//      https://api-docs.quran.foundation/docs/tutorials/oidc/client-setup/
//   3. Build. `APIConfig` will pick the right pair based on
//      `APIConfig.current` (.prelive vs .production).
//
// `Secrets.swift` is .gitignored — DO NOT commit your real credentials.

/*
import Foundation

struct Secrets: Sendable {
    let preliveClientId: String
    let preliveClientSecret: String
    let productionClientId: String
    let productionClientSecret: String

    static let shared = Secrets(
        preliveClientId:        "<your-prelive-client-id>",
        preliveClientSecret:    "<your-prelive-client-secret>",
        productionClientId:     "<your-production-client-id>",
        productionClientSecret: "<your-production-client-secret>"
    )
}
*/
