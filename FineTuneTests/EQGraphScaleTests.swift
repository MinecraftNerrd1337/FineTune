// FineTuneTests/EQGraphScaleTests.swift
//
// The dB window of the EQ Manager's graph stays within ±24 dB whatever sets it, and the fields
// of its scale and levels only take whole numbers.

import Testing
@testable import FineTune

@Suite("EQ graph scale — the dB window stays within ±24 dB")
struct EQGraphScaleTests {

    @Test("At ±12 dB the middle level goes from −12 to +12 dB, and a level past that stops there")
    func middleStaysInBounds() {
        var scale = EQGraphScale(span: 12)
        scale.setCenter(15)
        #expect(scale.center == 12)
        #expect(scale.top == 24)
        scale.setCenter(-30)
        #expect(scale.center == -12)
        #expect(scale.bottom == -24)
    }

    @Test("The top and bottom levels move the window and keep its scale")
    func topAndBottomMoveTheWindow() {
        var scale = EQGraphScale(span: 6)
        scale.setTop(10)
        #expect(scale.center == 4)
        #expect(scale.bottom == -2)
        scale.setBottom(-20)
        #expect(scale.center == -14)
        #expect(scale.top == -8)
        scale.setTop(40)
        #expect(scale.top == 24)
        #expect(scale.span == 6)
    }

    @Test("A wider scale keeps the middle level as far as the window allows")
    func widerScaleMovesTheMiddleIn() {
        var scale = EQGraphScale(span: 6, center: 15)
        scale.setSpan(12)
        #expect(scale.center == 12)
        scale.setSpan(24)
        #expect(scale.center == 0)
        scale.setSpan(30)
        #expect(scale.span == 24)
        scale.setSpan(0)
        #expect(scale.span == 1)
    }

    @Test("0 in the middle centers the window")
    func zeroCenters() {
        var scale = EQGraphScale(span: 9, center: -7)
        scale.setCenter(0)
        #expect(scale.top == 9)
        #expect(scale.bottom == -9)
    }

    @Test("Scrolling moves by whole dB and stops at the bounds")
    func scrollStops() {
        var scale = EQGraphScale(span: 20)
        scale.scroll(by: 3)
        #expect(scale.center == 3)
        scale.scroll(by: 10)
        #expect(scale.center == 4)
    }

    @Test("The fields keep digits and a leading sign only")
    func fieldsTakeWholeNumbers() {
        #expect(EQScaleNumberField.wholeNumberCharacters("+12 dB") == "+12")
        #expect(EQScaleNumberField.wholeNumberCharacters("1a2") == "12")
        #expect(EQScaleNumberField.wholeNumberCharacters("3-") == "3")
        #expect(EQScaleNumberField.number(in: "-") == nil)
        #expect(EQScaleNumberField.number(in: "+7") == 7)
        #expect(EQScaleNumberField.number(in: "−9") == -9)
    }
}
