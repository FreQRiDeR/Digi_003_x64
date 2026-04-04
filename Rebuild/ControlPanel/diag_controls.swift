import Foundation
import CoreAudio

func fourCC(_ value: UInt32) -> String {
    var v = value.bigEndian
    let data = Data(bytes: &v, count: 4)
    let s = String(data: data, encoding: .macOSRoman) ?? "????"
    let printable = s.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value <= 126 }
    return printable ? s : "????"
}

func str(_ objectID: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Unmanaged<CFString>? = nil
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let s = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(objectID, &a, 0, nil, &sz, $0) }
    if s != noErr { return "<err \(s)>" }
    return v?.takeRetainedValue() as String? ?? "<nil>"
}

func u32(_ objectID: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ elem: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> UInt32? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
    var v: UInt32 = 0
    var sz = UInt32(MemoryLayout<UInt32>.size)
    let s = AudioObjectGetPropertyData(objectID, &a, 0, nil, &sz, &v)
    return s == noErr ? v : nil
}

func u32arr(_ objectID: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ elem: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> [UInt32]? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: elem)
    var sz: UInt32 = 0
    if AudioObjectGetPropertyDataSize(objectID, &a, 0, nil, &sz) != noErr || sz == 0 { return nil }
    var arr = Array(repeating: UInt32(0), count: Int(sz) / MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(objectID, &a, 0, nil, &sz, &arr) != noErr { return nil }
    return arr
}

func selectorItemName(_ controlID: AudioObjectID, _ scope: AudioObjectPropertyScope, _ elem: AudioObjectPropertyElement, _ item: UInt32) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioSelectorControlPropertyItemName, mScope: scope, mElement: elem)
    var inVal = item
    var out: Unmanaged<CFString>? = nil
    var trans = withUnsafeMutablePointer(to: &inVal) { inPtr in
        withUnsafeMutablePointer(to: &out) { outPtr in
            AudioValueTranslation(mInputData: inPtr, mInputDataSize: UInt32(MemoryLayout<UInt32>.size), mOutputData: outPtr, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
        }
    }
    var sz = UInt32(MemoryLayout<AudioValueTranslation>.size)
    let s = AudioObjectGetPropertyData(controlID, &a, 0, nil, &sz, &trans)
    if s != noErr { return "<err \(s)>" }
    return out?.takeRetainedValue() as String? ?? "<nil>"
}

var sys = AudioObjectID(kAudioObjectSystemObject)
var da = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var sz: UInt32 = 0
if AudioObjectGetPropertyDataSize(sys, &da, 0, nil, &sz) != noErr { exit(1) }
var devs = Array(repeating: AudioObjectID(0), count: Int(sz)/MemoryLayout<AudioObjectID>.size)
if AudioObjectGetPropertyData(sys, &da, 0, nil, &sz, &devs) != noErr { exit(1) }

print("Device count: \(devs.count)")
for d in devs where d != 0 {
    let name = str(d, kAudioObjectPropertyName)
    print("\n=== Device \(d): \(name) ===")
    if let cs = u32(d, kAudioDevicePropertyClockSource) {
        print("clock source: \(cs) \(fourCC(cs))")
    }

    var ca = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyControlList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var csz: UInt32 = 0
    if AudioObjectGetPropertyDataSize(d, &ca, 0, nil, &csz) != noErr || csz == 0 {
        print("no controls")
        continue
    }
    var ctrls = Array(repeating: AudioObjectID(0), count: Int(csz)/MemoryLayout<AudioObjectID>.size)
    if AudioObjectGetPropertyData(d, &ca, 0, nil, &csz, &ctrls) != noErr {
        print("control read failed")
        continue
    }
    print("controls: \(ctrls.count)")

    for c in ctrls where c != 0 {
        let cls = u32(c, kAudioObjectPropertyClass) ?? 0
        let cname = str(c, kAudioObjectPropertyName)
        let scope = u32(c, kAudioControlPropertyScope) ?? kAudioObjectPropertyScopeGlobal
        let elem = u32(c, kAudioControlPropertyElement) ?? kAudioObjectPropertyElementMain
        print("  control \(c) class=\(fourCC(cls))/\(cls) scope=\(fourCC(scope))/\(scope) elem=\(elem) name='\(cname)'")

        var hasAvail = AudioObjectPropertyAddress(mSelector: kAudioSelectorControlPropertyAvailableItems, mScope: scope, mElement: elem)
        if AudioObjectHasProperty(c, &hasAvail), let items = u32arr(c, kAudioSelectorControlPropertyAvailableItems, scope, elem) {
            let cur = u32(c, kAudioSelectorControlPropertyCurrentItem, scope, elem) ?? 0
            print("    selector current=\(cur)/\(fourCC(cur)) items=\(items)")
            for it in items {
                print("      \(it)/\(fourCC(it)) -> \(selectorItemName(c, scope, elem, it))")
            }
        }
    }
}
