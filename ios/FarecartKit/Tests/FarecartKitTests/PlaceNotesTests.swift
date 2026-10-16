import Foundation
import Testing
@testable import FarecartKit

@Suite("Place notes cleanup")
struct PlaceNotesTests {
    @Test("Everything from UNSURE on is dropped")
    func unsure() {
        let notes = PlaceNotes.clean("UNSURE: aldi.us locator blocks automated fetching; address and hours from third-party listing - confirm by phone. CTA: Blue Line Central; #85 Central.")
        #expect(notes.body == nil)
        #expect(notes.transitHint == nil)   // the CTA sentence came after UNSURE, so it is gone too
    }

    @Test("Citations and provenance are hidden, the CTA hint is kept")
    func provenance() {
        let notes = PlaceNotes.clean("Address confirmed on Pete's official store list (store #10). Hours from third-party listings (petesfresh.com shows no hours) - confirm by phone. EBT per chain policy. CTA: #20 Madison bus; Blue Line Western (Forest Park branch).")
        #expect(notes.body == nil)
        #expect(notes.transitHint == "#20 Madison bus; Blue Line Western (Forest Park branch).")
    }

    @Test("Rider-facing sentences survive")
    func riderFacing() {
        let notes = PlaceNotes.clean("Run by Above and Beyond Family Recovery Center; open six days a week; serves Garfield Park, Austin, North Lawndale. Served by GCFD; Plentiful listing above-and-beyond-00ce5261. Hours as of Jan 2026. CTA: Blue Line Pulaski ~0.3 mi; #53 Pulaski.")
        #expect(notes.body == "Run by Above and Beyond Family Recovery Center; open six days a week; serves Garfield Park, Austin, North Lawndale.")
        #expect(notes.transitHint == "Blue Line Pulaski ~0.3 mi; #53 Pulaski.")
    }

    @Test("Parenthetical citations with URLs never show")
    func urls() {
        let notes = PlaceNotes.clean("Outdoor grocery/produce distribution supplied by Greater Chicago Food Depository (GCFD listing chicagosfoodbank.org/locations/mccormick-ymca/ agrees). Bring a cart.")
        #expect(notes.body == "Bring a cart.")
        #expect(PlaceNotes.clean("OSM node openstreetmap.org/node/22 (© OpenStreetMap contributors). Ring the bell.").body == "Ring the bell.")
        #expect(PlaceNotes.containsURL("see https://example.org"))
        #expect(PlaceNotes.containsURL("petesfresh.com shows no hours"))
        #expect(!PlaceNotes.containsURL("open six days a week"))
    }

    @Test("Simple notes pass through; empty input is empty")
    func passthrough() {
        #expect(PlaceNotes.clean("Bring your own bags.").body == "Bring your own bags.")
        #expect(PlaceNotes.clean("   ") == .empty)
        #expect(PlaceNotes.clean(nil) == .empty)
        #expect(MockData.samplePantry.publicNotes.body == "Bring your own bags.")
    }
}
