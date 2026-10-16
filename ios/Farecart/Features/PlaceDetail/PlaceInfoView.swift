import SwiftUI
import UIKit
import MapKit
import FarecartKit

/// The Info tab of a place: two cards (Visit, Good to know) and a short verification footer.
struct PlaceInfoView: View {
    let place: Place
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL
    @State private var copiedAddress = false
    /// Apple's record for this place, when `MKLocalSearch` finds one within 150 m. Drives the
    /// "More on Apple Maps" row and the system place card (photos, hours, reviews).
    @State private var appleItem: MKMapItem?
    @State private var showsAppleCard = false

    var body: some View {
        VStack(spacing: Spacing.m) {
            visitCard
            if hasGoodToKnow {
                goodToKnowCard
            }
            footer
        }
        .task(id: place.id) {
            appleItem = await environment.applePlaces.mapItem(for: place)
        }
        .mapItemDetailSheet(isPresented: $showsAppleCard, item: appleItem)
    }

    // MARK: Visit

    private var visitCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            addressRow
            Divider()
            hoursRow
            if let phone = place.phone, let url = place.phoneURL {
                Divider()
                InfoRow(systemImage: "phone.fill", tint: place.type.color, title: "Phone") {
                    Link(phone, destination: url)
                        .accessibilityHint("Calls this place")
                }
            }
            if let url = place.websiteURL {
                Divider()
                InfoRow(systemImage: "safari.fill", tint: place.type.color, title: "Website") {
                    Link(url.host() ?? url.absoluteString, destination: url)
                }
            }
            if appleItem != nil {
                Divider()
                appleRow
            }
        }
        .card()
    }

    /// Opens Apple's place card for this location. Hidden when Apple has no matching record.
    private var appleRow: some View {
        Button {
            showsAppleCard = true
        } label: {
            InfoRow(systemImage: "photo.on.rectangle.angled", tint: place.type.color, title: "More on Apple Maps") {
                Text("Photos, hours and reviews from Apple")
                    .foregroundStyle(.primary)
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Apple's place card with photos, hours and reviews")
    }

    private var addressRow: some View {
        Menu {
            Button {
                UIPasteboard.general.string = place.address
                copiedAddress = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copiedAddress = false
                }
            } label: {
                Label("Copy address", systemImage: "doc.on.doc")
            }
            Button {
                Directions.openAppleMapsTransit(to: place)
            } label: {
                Label("Open in Apple Maps", systemImage: "map.fill")
            }
            Button {
                Directions.openGoogleMapsTransit(to: place)
            } label: {
                Label("Open in Google Maps", systemImage: "globe.americas.fill")
            }
        } label: {
            InfoRow(systemImage: "mappin.and.ellipse", tint: place.type.color, title: copiedAddress ? "Copied" : "Address") {
                Text(place.address)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let neighborhood = place.neighborhood {
                    Text(neighborhood).foregroundStyle(.secondary).font(.subheadline)
                }
            } trailing: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copy the address or open it in a maps app")
    }

    private var hoursRow: some View {
        InfoRow(systemImage: "clock.fill", tint: place.type.color, title: "Hours") {
            let status = place.openStatus()
            if case .unknown = status {} else {
                OpenStatusLabel(status: status).font(.subheadline.weight(.semibold))
            }
            if let text = place.hoursText, !text.isEmpty {
                Text(text)
            } else if let hours = place.hours {
                Text(hours.sorted { $0.key < $1.key }.map { "\($0.key.capitalized) \($0.value)" }.joined(separator: "\n"))
            } else {
                Text("Hours not listed. Call ahead if you can.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Good to know

    private var notes: PlaceNotes { place.publicNotes }

    private var hasGoodToKnow: Bool {
        place.type == .grocery
            || !(place.requirements ?? "").isEmpty
            || !place.languages.isEmpty
            || notes.body != nil
            || notes.transitHint != nil
    }

    private var goodToKnowCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionCaption("Good to know")
            if place.type == .grocery {
                HStack(spacing: Spacing.xs) {
                    switch place.acceptsEBT {
                    case true?:
                        Pill(text: Text("Takes Link/EBT"), systemImage: "creditcard.fill", tint: .green)
                    case false?:
                        Pill(text: Text("Does not take Link/EBT"), systemImage: "creditcard", tint: .secondary)
                    default:
                        Pill(text: Text("Link/EBT: ask at the store"), systemImage: "questionmark.circle", tint: .secondary)
                    }
                }
            }
            if let requirements = place.requirements, !requirements.isEmpty {
                InfoRow(systemImage: "checklist", tint: place.type.color, title: "What to bring") { Text(requirements) }
            } else if place.type != .grocery {
                InfoRow(systemImage: "checkmark.circle", tint: place.type.color, title: "What to bring") {
                    Text("No requirements listed").foregroundStyle(.secondary)
                }
            }
            if !place.languages.isEmpty {
                InfoRow(systemImage: "globe", tint: place.type.color, title: "Languages") {
                    Text(place.languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", "))
                }
            }
            if let hint = notes.transitHint {
                InfoRow(systemImage: "bus.fill", tint: place.type.color, title: "Nearby CTA") { Text(hint) }
            }
            if let body = notes.body {
                InfoRow(systemImage: "text.alignleft", tint: place.type.color, title: "Notes") { Text(body) }
            }
        }
        .card()
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let verifiedOn = place.verifiedOn {
                Label("Verified on \(verifiedOn.formatted(date: .long, time: .omitted))", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Not yet verified by our team. Hours and rules may have changed. Call ahead if you can.", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            if let source = place.sourceURL, let url = URL(string: source) {
                Link(destination: url) {
                    Label {
                        Text(LocalizedStringResource(stringLiteral: place.sourceDescription))
                    } icon: {
                        Image(systemName: "link")
                    }
                }
            } else {
                Label(LocalizedStringResource(stringLiteral: place.sourceDescription), systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            if let url = DirectionsLinks.reportProblemEmail(to: environment.reportProblemEmail, placeName: place.name, placeID: place.id) {
                Link(destination: url) {
                    Label("Report a problem with this listing", systemImage: "flag")
                }
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// Icon in the place's color, small uppercase title, then the value.
struct InfoRow<Content: View, Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let title: LocalizedStringResource
    @ViewBuilder let content: () -> Content
    @ViewBuilder let trailing: () -> Trailing

    init(
        systemImage: String,
        tint: Color,
        title: LocalizedStringResource,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.content = content
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                SectionCaption(title)
                content()
                    .font(.body)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ScrollView {
        PlaceInfoView(place: MockData.samplePantry).padding()
    }
    .background(Color(.systemGroupedBackground))
    .environment(AppEnvironment.preview())
}
