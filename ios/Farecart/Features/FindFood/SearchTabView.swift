import SwiftUI
import FarecartKit

/// The search-role tab: type an address or neighborhood, or pick a suggestion.
struct SearchTabView: View {
    @Bindable var model: FindFoodModel
    @Binding var selectedTab: AppTab

    private let suggestions = [
        "Austin, Chicago", "Garfield Park, Chicago", "North Lawndale, Chicago",
        "Humboldt Park, Chicago", "Little Village, Chicago", "West Town, Chicago",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            await model.useMyLocation()
                            if model.errorMessage == nil { selectedTab = .find }
                        }
                    } label: {
                        Label {
                            Text("Use my location")
                                .font(.headline)
                        } icon: {
                            if model.isLocating { ProgressView() } else { Image(systemName: "location.fill") }
                        }
                    }
                    .disabled(model.isLocating)
                }

                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if model.isGeocoding {
                    Section { ProgressView("Looking up address…") }
                } else if !model.geocodeResults.isEmpty {
                    Section("Matches") {
                        ForEach(model.geocodeResults) { result in
                            Button {
                                Task {
                                    await model.choose(result)
                                    selectedTab = .find
                                }
                            } label: {
                                Label(result.label, systemImage: "mappin.and.ellipse")
                            }
                        }
                    }
                }

                Section("Neighborhoods") {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            model.searchText = suggestion
                            Task {
                                await model.searchAndUseFirstMatch()
                                if model.errorMessage == nil { selectedTab = .find }
                            }
                        } label: {
                            Label(suggestion, systemImage: "building.2")
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $model.searchText, prompt: Text("Address, ZIP or neighborhood"))
            .onSubmit(of: .search) {
                Task {
                    await model.searchAndUseFirstMatch()
                    if model.errorMessage == nil { selectedTab = .find }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var tab: AppTab = .search
    let environment = AppEnvironment.preview()
    SearchTabView(model: FindFoodModel(environment: environment), selectedTab: $tab)
        .environment(environment)
}
