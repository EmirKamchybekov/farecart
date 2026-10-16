import Foundation
import Observation
import FarecartKit

/// Loads `fares` and `programs` once, falling back to the bundled copies when offline.
@MainActor
@Observable
final class FareStore {
    private(set) var fares: [Fare] = []
    private(set) var programs: [Program] = []
    /// `true` while showing bundled (last-known) rows instead of live data.
    private(set) var isUsingFallback = false
    private(set) var isLoading = false
    private(set) var lastError: String?
    private var loaded = false

    private let data: any FoodDataProviding

    init(data: any FoodDataProviding) {
        self.data = data
    }

    var calculator: FareCalculator { FareCalculator(fares: fares) }

    func program(forKey key: String?) -> Program? {
        guard let key else { return nil }
        return programs.first { $0.key == key }
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let fareRows = data.fares()
            async let programRows = data.programs()
            let (f, p) = try await (fareRows, programRows)
            fares = f.isEmpty ? BundledFallbacks.fares : f
            programs = p.isEmpty ? BundledFallbacks.programs : p
            isUsingFallback = f.isEmpty || p.isEmpty
            lastError = nil
            loaded = true
        } catch {
            fares = BundledFallbacks.fares
            programs = BundledFallbacks.programs
            isUsingFallback = true
            lastError = error.localizedDescription
            // Leave `loaded` false so a later call retries the network.
        }
    }
}
