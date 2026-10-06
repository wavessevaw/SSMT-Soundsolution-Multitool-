import XCTest
@testable import SSMTCore

final class InputListTests: XCTestCase {
    func band() -> InputListDocument {
        var d = InputListDocument()
        d.insert(ChannelTemplate.template(id: "drums")!)
        d.insert(ChannelTemplate.template(id: "bass")!)
        d.insert(ChannelTemplate.template(id: "leadVocal")!)
        return d
    }

    func testTemplatesNumberConsecutively() {
        let d = band()
        XCTAssertEqual(d.channels.map(\.number), Array(1...13))
        XCTAssertEqual(d.channels.first?.source, "Kick In")
        XCTAssertEqual(d.channels.last?.source, "Lead Vox")
        XCTAssertTrue(d.issues.isEmpty, "\(d.issues)")
    }

    func testInsertInTheMiddleShiftsFollowingChannels() {
        var d = band()
        let snareTop = d.channels[2].id
        d.addChannel(after: snareTop)
        XCTAssertEqual(d.channels.map(\.number), Array(1...14))
        XCTAssertEqual(d.channels[3].source, "")
        XCTAssertEqual(d.channels[4].source, "Snare Bottom")
        XCTAssertEqual(d.channels[4].number, 5)
    }

    func testManualGapsAreKept() {
        var d = InputListDocument()
        d.channels = [InputChannel(number: 1, source: "A"), InputChannel(number: 2, source: "B"),
                      InputChannel(number: 9, source: "Spare block")]
        d.addChannel(after: d.channels[0].id)
        XCTAssertEqual(d.channels.map(\.number), [1, 2, 3, 9], "the gap before 9 stays")
    }

    func testStereoPair() {
        var d = InputListDocument()
        let id = d.addChannel()
        d.channels[0].source = "Keys"
        d.channels[0].stagebox = "SB1-07"
        let r = d.makeStereo(id)
        XCTAssertNotNil(r)
        XCTAssertEqual(d.channels.map(\.source), ["Keys L", "Keys R"])
        XCTAssertEqual(d.channels.map(\.number), [1, 2])
        XCTAssertEqual(d.channels[1].stagebox, "SB1-08")
    }

    func testMoveKeepsNumberingByRow() {
        var d = band()
        let tom1 = d.channels[5].id
        d.move([tom1], by: -1)
        XCTAssertEqual(d.channels[4].source, "Tom 1")
        XCTAssertEqual(d.channels[4].number, 5)
        XCTAssertEqual(d.channels[5].source, "Hi-Hat")
        d.move(fromOffsets: IndexSet(integer: 12), toOffset: 0)
        XCTAssertEqual(d.channels[0].source, "Lead Vox")
        XCTAssertEqual(d.channels.map(\.number), Array(1...13))
    }

    func testDeleteRenumberDuplicate() {
        var d = band()
        d.delete([d.channels[0].id, d.channels[1].id])
        XCTAssertEqual(d.channels.first?.number, 3)
        d.renumber()
        XCTAssertEqual(d.channels.map(\.number), Array(1...11))
        d.duplicate([d.channels[0].id])
        XCTAssertEqual(d.channels[1].source, d.channels[0].source)
        XCTAssertEqual(d.channels.map(\.number), Array(1...12))
    }

    func testStageboxAssignmentAndIssues() {
        var d = band()
        d.assignStagebox(prefix: "SB1-")
        XCTAssertEqual(d.channels.first?.stagebox, "SB1-01")
        XCTAssertEqual(d.channels.last?.stagebox, "SB1-13")
        d.channels[3].stagebox = "SB1-01"
        d.channels[4].number = 1
        d.channels[5].source = " "
        XCTAssertTrue(d.issues.contains(.duplicateStagebox("SB1-01")))
        XCTAssertTrue(d.issues.contains(.duplicateNumber(1)))
        XCTAssertTrue(d.issues.contains(.emptySource(channel: 6)))
    }

    func testSummary() {
        var d = band()
        d.addMix(type: .iem)
        d.mixes[0].stereo = true
        d.addMix()
        let s = d.summary
        XCTAssertEqual(s.channelCount, 13)
        XCTAssertEqual(s.models.first?.name, "e604")
        XCTAssertEqual(s.models.first?.count, 3)
        XCTAssertEqual(s.phantomCount, d.channels.filter(\.phantom).count)
        XCTAssertTrue(s.stands.contains { $0.type == .tallBoom && $0.count == 3 })
        XCTAssertEqual(s.mixCount, 2)
        XCTAssertEqual(s.stereoMixCount, 1)
    }

    func testCSVEscaping() {
        var d = InputListDocument()
        d.channels = [InputChannel(number: 1, source: "Vox, \"lead\"", mic: "SM58", phantom: false)]
        let csv = d.channelsCSV
        XCTAssertTrue(csv.hasPrefix("Ch,Source,Mic/DI"))
        XCTAssertTrue(csv.contains("1,\"Vox, \"\"lead\"\"\",SM58"))
    }

    func testRoundTripAndVersion() throws {
        var d = band()
        d.artist = "Band"
        d.date = Date(timeIntervalSince1970: 1_800_000_000)
        d.stage.add(.drumKit, at: (5, 4))
        d.stage.add(.text, label: "FOH →")
        let back = try InputListDocument.decode(d.encoded())
        XCTAssertEqual(back, d)
        var newer = d
        newer.version = 99
        XCTAssertThrowsError(try InputListDocument.decode(newer.encoded()))
    }

    func testPagination() {
        var d = InputListDocument()
        for _ in 0..<45 { d.addChannel() }
        let pages = d.channelPages(rowsPerPage: 20)
        XCTAssertEqual(pages.map(\.count), [20, 20, 5])
        XCTAssertEqual(pages[1].first?.number, 21)
    }

    func testStagePlanEditing() {
        var p = StagePlan()
        let id = p.add(.wedge, at: (3.13, 1.07))
        p.move(id, to: (3.13, 1.07))
        XCTAssertEqual(p.items[0].x, 3.25, accuracy: 1e-9, "snapped to the 0.25 m grid")
        XCTAssertEqual(p.items[0].y, 1.0, accuracy: 1e-9)
        p.move(id, to: (50, -3))
        XCTAssertEqual(p.items[0].x, p.width)
        XCTAssertEqual(p.items[0].y, 0)
        p.rotate(id, by: -90)
        XCTAssertEqual(p.items[0].rotation, 270)
        let copy = p.duplicate(id)!
        p.sendToBack(copy)
        XCTAssertEqual(p.items.first?.id, copy)
        p.bringToFront(copy)
        XCTAssertEqual(p.items.last?.id, copy)
        p.remove([id])
        XCTAssertEqual(p.items.count, 1)
        p.width = 4
        p.items[0].x = 9
        p.clampAll()
        XCTAssertEqual(p.items[0].x, 4)
    }

    func testMicLibrary() {
        XCTAssertEqual(MicLibrary.suggestions(for: "sm").first, "SM58")
        XCTAssertTrue(MicLibrary.suggestions(for: "414").contains("C414"))
        XCTAssertTrue(MicLibrary.needsPhantom("KM184"))
        XCTAssertTrue(MicLibrary.needsPhantom("DI"))
        XCTAssertFalse(MicLibrary.needsPhantom("SM58"))
        XCTAssertFalse(MicLibrary.needsPhantom("MD421"))
        XCTAssertFalse(MicLibrary.needsPhantom("Radial ProD2"))
    }

    func testStarterAndSuggestedName() {
        let s = InputListDocument.starter
        XCTAssertTrue(s.channels.isEmpty)
        XCTAssertEqual(s.stage.items.map(\.kind), [.riser, .drumKit, .person, .wedge, .text])
        XCTAssertEqual(s.stage.items.map(\.label), ["Drum riser", "Drums", "Lead vocal", "Mix 1", "Audience"])
        XCTAssertEqual(s.stage.items[3].y, 0.4, accuracy: 1e-9)
        var d = InputListDocument()
        XCTAssertEqual(d.suggestedName, "Ptch")
        d.artist = " AC/DC "
        XCTAssertEqual(d.suggestedName, "AC-DC")
        d.event = "Club"
        XCTAssertEqual(d.suggestedName, "AC-DC - Club")
        d.artist = ""
        XCTAssertEqual(d.suggestedName, "Club")
    }
}
