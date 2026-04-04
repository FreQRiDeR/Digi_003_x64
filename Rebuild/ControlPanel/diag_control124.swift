import Foundation
import CoreAudio

struct Sel { let name: String; let value: AudioObjectPropertySelector; let kind: String }

let sels: [Sel] = [
    Sel(name: "kAudioObjectPropertyClass", value: kAudioObjectPropertyClass, kind: "u32"),
    Sel(name: "kAudioObjectPropertyBaseClass", value: kAudioObjectPropertyBaseClass, kind: "u32"),
    Sel(name: "kAudioObjectPropertyOwner", value: kAudioObjectPropertyOwner, kind: "u32"),
    Sel(name: "kAudioControlPropertyScope", value: kAudioControlPropertyScope, kind: "u32"),
    Sel(name: "kAudioControlPropertyElement", value: kAudioControlPropertyElement, kind: "u32"),
    Sel(name: "kAudioBooleanControlPropertyValue", value: kAudioBooleanControlPropertyValue, kind: "u32"),
    Sel(name: "kAudioSelectorControlPropertyCurrentItem", value: kAudioSelectorControlPropertyCurrentItem, kind: "u32"),
    Sel(name: "kAudioSelectorControlPropertyAvailableItems", value: kAudioSelectorControlPropertyAvailableItems, kind: "arr"),
    Sel(name: "kAudioSelectorControlPropertyItemKind", value: kAudioSelectorControlPropertyItemKind, kind: "u32"),
    Sel(name: "kAudioLevelControlPropertyScalarValue", value: kAudioLevelControlPropertyScalarValue, kind: "f32"),
    Sel(name: "kAudioLevelControlPropertyDecibelValue", value: kAudioLevelControlPropertyDecibelValue, kind: "f32"),
    Sel(name: "kAudioLevelControlPropertyDecibelRange", value: kAudioLevelControlPropertyDecibelRange, kind: "bytes"),
]

func fourCC(_ value: UInt32) -> String {
    var v = value.bigEndian
    let data = Data(bytes: &v, count: 4)
    let s = String(data: data, encoding: .macOSRoman) ?? "????"
    let printable = s.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value <= 126 }
    return printable ? s : "????"
}

func getDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var list = Array(repeating: AudioObjectID(0), count: Int(size)/MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &list) == noErr else { return [] }
    return list
}

func getName(_ id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    guard status == noErr else { return "<err \(status)>" }
    return value?.takeRetainedValue() as String? ?? "<nil>"
}

func getU32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var sz = UInt32(MemoryLayout<UInt32>.size)
    let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &v)
    return st == noErr ? v : 0
}

func findAvidDevice() -> AudioObjectID? {
    for d in getDevices() where d != 0 {
        let n = getName(d).lowercased()
        if n.contains("avid") || n.contains("digi") || n.contains("002") || n.contains("003") {
            return d
        }
    }
    return nil
}

func getControls(_ dev: AudioObjectID) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyControlList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr else { return [] }
    var list = Array(repeating: AudioObjectID(0), count: Int(size)/MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &list) == noErr else { return [] }
    return list
}

let scopes: [AudioObjectPropertyScope] = [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput, kAudioDevicePropertyScopePlayThrough]
let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1,2,3,4,5,6,7,8]

guard let dev = findAvidDevice() else {
    print("No Avid device")
    exit(0)
}
print("Device \(dev): \(getName(dev))")
let controls = getControls(dev)
print("Controls: \(controls)")

for c in controls where c != 0 {
    let cls = getU32(c, kAudioObjectPropertyClass)
    print("\n=== Control \(c) class=\(fourCC(cls))/\(cls) name=\(getName(c)) ===")
    for sel in sels {
        for scope in scopes {
            for elem in elements {
                var addr = AudioObjectPropertyAddress(mSelector: sel.value, mScope: scope, mElement: elem)
                if !AudioObjectHasProperty(c, &addr) { continue }
                var dataSize: UInt32 = 0
                let infoStatus = AudioObjectGetPropertyDataSize(c, &addr, 0, nil, &dataSize)
                if infoStatus != noErr {
                    print("  \(sel.name) scope=\(fourCC(scope)) elem=\(elem) sizeErr=\(infoStatus)")
                    continue
                }
                var bytes = [UInt8](repeating: 0, count: Int(max(dataSize, 1)))
                var mutableSize = dataSize
                let status = AudioObjectGetPropertyData(c, &addr, 0, nil, &mutableSize, &bytes)
                if status == noErr {
                    if sel.kind == "u32" && mutableSize >= 4 {
                        let v = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
                        print("  \(sel.name) scope=\(fourCC(scope)) elem=\(elem) -> \(v) (\(fourCC(v)))")
                    } else if sel.kind == "f32" && mutableSize >= 4 {
                        let v = bytes.withUnsafeBytes { $0.load(as: Float32.self) }
                        print("  \(sel.name) scope=\(fourCC(scope)) elem=\(elem) -> \(v)")
                    } else if sel.kind == "arr" && mutableSize >= 4 {
                        let count = Int(mutableSize)/4
                        let arr = (0..<count).map { i -> UInt32 in
                            bytes.withUnsafeBytes { $0.load(fromByteOffset: i*4, as: UInt32.self) }
                        }
                        print("  \(sel.name) scope=\(fourCC(scope)) elem=\(elem) -> \(arr.map { "\($0)/\(fourCC($0))" })")
                    } else {
                        print("  \(sel.name) scope=\(fourCC(scope)) elem=\(elem) -> \(mutableSize) bytes")
                    }
                } else {
                    print("  \(sel.name) scope=\(fourCC(scope)) elem=\(elem) readErr=\(status) size=\(dataSize)")
                }
            }
        }
    }
}
