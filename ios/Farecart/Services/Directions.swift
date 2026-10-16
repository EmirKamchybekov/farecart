import MapKit
import UIKit
import FarecartKit

/// Opens transit directions in Apple Maps or Google Maps.
@MainActor
enum Directions {
    /// Apple Maps with transit directions (Bus/Train = CTA in Chicago).
    static func openAppleMapsTransit(to place: Place) {
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let item = MKMapItem(location: location, address: MKAddress(fullAddress: place.address, shortAddress: nil))
        item.name = place.name
        let opened = item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit
        ])
        if !opened {
            UIApplication.shared.open(DirectionsLinks.appleMapsTransit(to: place.coordinate, name: place.name))
        }
    }

    /// Google Maps app when installed (needs `comgooglemaps` in LSApplicationQueriesSchemes), else the website.
    static func openGoogleMapsTransit(to place: Place) {
        let app = DirectionsLinks.googleMapsApp(to: place.coordinate)
        if UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else {
            UIApplication.shared.open(DirectionsLinks.googleMapsWeb(to: place.coordinate))
        }
    }

    static var isGoogleMapsInstalled: Bool {
        UIApplication.shared.canOpenURL(DirectionsLinks.googleMapsApp(to: .westSideChicago))
    }
}
