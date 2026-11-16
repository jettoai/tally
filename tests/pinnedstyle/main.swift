import Foundation

// PinnedStyle.resolve: the stored pin choice, current keys first, the single legacy key only when
// the new form key is absent. Compiled with Tally/Stores/DisplaySettings.swift only.
var fails = 0

func check(_ name: String, form: String?, axis: String?, legacy: String?, _ style: PinnedStyle, _ direction: PinnedAxis) {
    let got = PinnedStyle.resolve(form: form, axis: axis, legacy: legacy)
    if got.0 == style && got.1 == direction {
        print("PASS: \(name)")
    } else {
        print("FAIL: \(name): got (\(got.0), \(got.1)), want (\(style), \(direction))")
        fails += 1
    }
}

check("nothing stored", form: nil, axis: nil, legacy: nil, .full, .vertical)
check("legacy full", form: nil, axis: nil, legacy: "full", .full, .vertical)
check("legacy row becomes labeled horizontal", form: nil, axis: nil, legacy: "row", .labeled, .horizontal)
check("legacy column becomes labeled vertical", form: nil, axis: nil, legacy: "column", .labeled, .vertical)
check("legacy garbage", form: nil, axis: nil, legacy: "garbage", .full, .vertical)
check("new keys win over the legacy key", form: "rings", axis: "horizontal", legacy: "column", .rings, .horizontal)
check("form without axis defaults vertical", form: "labeled", axis: nil, legacy: nil, .labeled, .vertical)
check("unknown form and axis", form: "bogus", axis: "bogus", legacy: nil, .full, .vertical)
check("axis key alone keeps the legacy style", form: nil, axis: "horizontal", legacy: "full", .full, .horizontal)
check("form present ignores a legacy row for direction", form: "rings", axis: nil, legacy: "row", .rings, .vertical)

if PinnedStyle.allCases == [.rings, .labeled, .full] && PinnedAxis.allCases == [.vertical, .horizontal] {
    print("PASS: case order")
} else {
    print("FAIL: case order")
    fails += 1
}

if fails > 0 { print("\(fails) failed"); exit(1) }
print("ALL PASS")
