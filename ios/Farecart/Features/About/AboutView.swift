import SwiftUI
import UIKit
import FarecartKit

/// Settings / About sheet: what the app is, where data comes from, how to report a problem.
struct AboutView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Farecart", systemImage: "basket.fill")
                            .font(.title2.weight(.bold))
                        Text("Find food. Get there for less.")
                            .font(.headline)
                        Text("Farecart helps people on Chicago's West Side find grocery stores, food pantries and giveaways nearby, and shows the cheapest CTA fare they qualify for.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section("Data sources") {
                    credit(title: "Food locations", detail: "Hand-researched by the Farecart team from public listings. Each place links to its source. Listings marked \"not yet verified\" have not been confirmed by phone or visit.")
                    credit(title: "CTA fares", detail: "Chicago Transit Authority, transitchicago.com/fares", url: "https://www.transitchicago.com/fares/")
                    credit(title: "Access reduced fare", detail: "Northern Illinois Transit Authority, getaccess.org", url: "https://getaccess.org")
                    credit(title: "Student reduced fare", detail: "CTA Ventra Student Card", url: "https://www.transitchicago.com/fares/reduced-fare/")
                    credit(title: "Maps", detail: "Apple Maps. Directions open in Apple Maps or Google Maps.")
                }

                Section("Privacy") {
                    Text("Your location is used only to search for nearby places. It is sent to our database for that search and never stored. Your Discounts answers stay on this phone.")
                        .font(.subheadline)
                }

                Section("Help") {
                    if let url = DirectionsLinks.reportProblemEmail(to: environment.reportProblemEmail, placeName: nil, placeID: nil) {
                        Link(destination: url) {
                            Label("Report a problem with a listing", systemImage: "flag")
                        }
                    }
                    Text("Email \(environment.reportProblemEmail) if a place has closed, moved or changed its hours.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Version", value: version)
                    if environment.config == nil {
                        Label("Running on sample data (no Supabase settings found).", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func credit(title: LocalizedStringResource, detail: LocalizedStringResource, url: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            if let url, let link = URL(string: url) {
                Link(link.host() ?? url, destination: link).font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    AboutView()
        .environment(AppEnvironment.preview())
}
