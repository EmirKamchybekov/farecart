import SwiftUI
import UIKit
import FarecartKit

/// Tab 1 → row → this. Hero card, facts, the in-app CTA directions button (plus Apple / Google
/// Maps as backups), then the fare line.
struct PlaceDetailView: View {
    let place: Place
    /// Where the Find Food tab is searching from; the in-app route starts here.
    var origin: GeoPoint? = nil
    var originLabel: String = ""
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                facts
                directions
                FareLineView()
                reportProblem
            }
            .padding()
        }
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: place.type.symbolName)
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(place.type.color, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.title2.weight(.bold))
                    TypeBadge(type: place.type, prominent: true)
                }
            }
            if let meters = place.distanceMeters {
                Label("\(Distance.milesText(meters: meters)) away · about \(Distance.walkingMinutes(meters: meters)) min walk", systemImage: "figure.walk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 14) {
            factRow(systemImage: "mappin", title: "Address") {
                Text(place.address)
                if let neighborhood = place.neighborhood { Text(neighborhood).foregroundStyle(.secondary) }
            }
            factRow(systemImage: "clock", title: "Hours") {
                if let text = place.hoursText, !text.isEmpty {
                    Text(text)
                } else if let hours = place.hours {
                    Text(hours.sorted { $0.key < $1.key }.map { "\($0.key.capitalized) \($0.value)" }.joined(separator: "\n"))
                } else {
                    Text("Hours not listed. Call ahead if you can.").foregroundStyle(.secondary)
                }
                OpenStatusLabel(status: place.openStatus()).font(.subheadline.weight(.semibold))
            }
            if let phone = place.phone, let url = place.phoneURL {
                factRow(systemImage: "phone", title: "Phone") {
                    Link(phone, destination: url)
                        .accessibilityHint("Calls this place")
                }
            }
            if place.type == .grocery {
                factRow(systemImage: "creditcard", title: "Link/EBT") {
                    switch place.acceptsEBT {
                    case true?: Text("Takes Link/EBT").foregroundStyle(.green)
                    case false?: Text("Does not take Link/EBT")
                    default: Text("Unknown. Ask at the store.").foregroundStyle(.secondary)
                    }
                }
            }
            if let requirements = place.requirements, !requirements.isEmpty {
                factRow(systemImage: "checklist", title: "What to bring") { Text(requirements) }
            }
            if !place.languages.isEmpty {
                factRow(systemImage: "globe", title: "Languages") {
                    Text(place.languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", "))
                }
            }
            if let notes = place.notes, !notes.isEmpty {
                factRow(systemImage: "note.text", title: "Notes") { Text(notes) }
            }
            if let url = place.websiteURL {
                factRow(systemImage: "safari", title: "Website") { Link(url.host() ?? url.absoluteString, destination: url) }
            }
            verification
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var verification: some View {
        if let verifiedOn = place.verifiedOn {
            Label("Verified on \(verifiedOn.formatted(date: .long, time: .omitted))", systemImage: "checkmark.seal.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        } else {
            Label("Not yet verified by our team. Hours and rules may have changed. Call ahead if you can.", systemImage: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Label(LocalizedStringResource(stringLiteral: place.sourceDescription), systemImage: "doc.text.magnifyingglass")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var routeRequest: RouteRequest {
        RouteRequest(
            origin: origin ?? .westSideChicago,
            originLabel: originLabel.isEmpty ? String(localized: "West Side, Chicago") : originLabel,
            place: place
        )
    }

    private var directions: some View {
        VStack(spacing: 12) {
            NavigationLink {
                RouteView(request: routeRequest)
            } label: {
                BigButtonLabel(title: "Directions by CTA", systemImage: "bus.fill")
            }
            .buttonStyle(.glassProminent)
            .accessibilityHint("Shows bus and train directions with your fare")

            Button {
                Directions.openAppleMapsTransit(to: place)
            } label: {
                BigButtonLabel(title: "Open in Apple Maps", systemImage: "map.fill")
            }
            .buttonStyle(.glass)
            .accessibilityHint("Opens Apple Maps with bus and train directions")

            Button {
                Directions.openGoogleMapsTransit(to: place)
            } label: {
                BigButtonLabel(title: "Open in Google Maps", systemImage: "map")
            }
            .buttonStyle(.glass)
            .accessibilityHint("Opens Google Maps with transit directions")
        }
    }

    private var reportProblem: some View {
        Group {
            if let url = DirectionsLinks.reportProblemEmail(to: environment.reportProblemEmail, placeName: place.name, placeID: place.id) {
                Link(destination: url) {
                    Label("Report a problem with this listing", systemImage: "flag")
                        .font(.footnote)
                }
            }
            if let source = place.sourceURL, let url = URL(string: source) {
                Link(destination: url) {
                    Label("Source", systemImage: "link")
                        .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func factRow<Content: View>(systemImage: String, title: LocalizedStringResource, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(place.type.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                content()
                    .font(.body)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Bus: $1.10 with your Access discount (instead of $2.25)" for each mode, from the fares table
/// and the saved Discounts answers.
struct FareLineView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage(DiscountsKeys.householdSNAP) private var householdSNAP = false
    @AppStorage(DiscountsKeys.isStudent) private var isStudent = false

    private var answers: EligibilityAnswers {
        EligibilityAnswers(householdReceivesSNAP: householdSNAP, isK12Student: isStudent)
    }

    var body: some View {
        let store = environment.fareStore
        let quotes = store.calculator.quotes(answers: answers)
        VStack(alignment: .leading, spacing: 10) {
            Label("Your fare", systemImage: "dollarsign.circle.fill")
                .font(.headline)
            if quotes.isEmpty {
                Text("Fare prices are not available right now.")
                    .foregroundStyle(.secondary)
            }
            ForEach(quotes, id: \.mode) { quote in
                fareLine(quote)
            }
            if !answers.householdReceivesSNAP && !answers.isK12Student {
                Text("Get SNAP or go to school? Check the Discounts tab to see if you can ride for less.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if store.isUsingFallback {
                Text("Showing last known prices (offline).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .task { await environment.fareStore.loadIfNeeded() }
    }

    @ViewBuilder
    private func fareLine(_ quote: FareQuote) -> some View {
        let modeName = Text(quote.mode.title)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: quote.mode.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            if quote.hasDiscount, let discounted = quote.discounted {
                let program = Text(programShortName(forKey: discounted.rider.programKey))
                let price = Text(quote.priceText()).bold()
                Text("\(modeName): \(price) with your \(program) discount (instead of \(quote.fullPriceText()))")
            } else {
                let price = Text(quote.priceText()).bold()
                Text("\(modeName): \(price) full fare")
            }
        }
        .font(.body)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Grocery") {
    NavigationStack {
        PlaceDetailView(place: MockData.samplePlace)
    }
    .environment(AppEnvironment.preview())
}

#Preview("Pantry, unverified") {
    NavigationStack {
        PlaceDetailView(place: MockData.samplePantry)
    }
    .environment(AppEnvironment.preview())
}
