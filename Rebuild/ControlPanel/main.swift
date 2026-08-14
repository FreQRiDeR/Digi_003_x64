import AppKit
import CoreAudio
import IOKit

// The control panel supports only Avid-branded Digi 002/003 hardware.
private let deviceFilterTokens = ["avid"]

private struct DeviceInfo {
    let id: AudioDeviceID
    let name: String
}

private struct ClockSourceInfo {
    let id: UInt32
    let name: String
}

private struct SelectorItemInfo {
    let id: UInt32
    let name: String
}

private struct SelectorControlInfo {
    let controlID: AudioObjectID
    let classID: AudioClassID
    let name: String
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement
    let currentItem: UInt32
    let items: [SelectorItemInfo]
}

private struct ProprietaryOpticalPropertyInfo {
    let objectID: AudioObjectID
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement
    let currentValue: UInt32
    let isSettable: Bool
}

private struct IOKitOpticalControlInfo {
    let currentValue: UInt32
}

private enum AudioError: Error {
    case osStatus(OSStatus, String)
}

@inline(__always)
private func checkStatus(_ status: OSStatus, _ context: String) throws {
    if status != noErr {
        throw AudioError.osStatus(status, context)
    }
}

private func cfStringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { valuePtr in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, valuePtr)
    }
    try checkStatus(status, "Read CFString selector \(selector)")
    return value?.takeRetainedValue() as String? ?? "Unknown"
}

private func findDevices() throws -> [DeviceInfo] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var byteSize: UInt32 = 0
    try checkStatus(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteSize),
                    "Get device list size")

    let count = Int(byteSize) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(0), count: count)
    try checkStatus(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteSize, &ids),
                    "Get device list")

    var devices: [DeviceInfo] = []
    for id in ids where id != 0 {
        if let name = try? cfStringProperty(id, selector: kAudioObjectPropertyName) {
            devices.append(DeviceInfo(id: id, name: name))
        }
    }

    return devices.filter { info in
        let lower = info.name.lowercased()
        return deviceFilterTokens.contains { lower.contains($0) }
            && (lower.contains("002") || lower.contains("003"))
    }
}

private func currentSampleRate(deviceID: AudioDeviceID) throws -> Double {
    var rate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    // Try reading output sample rate
    var status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)

    if status != noErr {
        // Fallback to global scope
        address.mScope = kAudioObjectPropertyScopeGlobal
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
    }

    try checkStatus(status, "Read current sample rate")
    return rate
}

private func uint32Property(objectID: AudioObjectID,
                            selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    try checkStatus(status, "Read UInt32 selector \(selector)")
    return value
}

private func uint32ArrayProperty(objectID: AudioObjectID,
                                 selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> [UInt32] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var byteSize: UInt32 = 0
    try checkStatus(AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &byteSize),
                    "Get array size selector \(selector)")
    if byteSize == 0 {
        return []
    }
    let count = Int(byteSize) / MemoryLayout<UInt32>.size
    var values = Array(repeating: UInt32(0), count: count)
    try checkStatus(AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteSize, &values),
                    "Get array selector \(selector)")
    return values
}

private func hasProperty(objectID: AudioObjectID,
                         selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope,
                         element: AudioObjectPropertyElement) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    return AudioObjectHasProperty(objectID, &address)
}

private func ownedObjectIDs(objectID: AudioObjectID) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyOwnedObjects,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var byteSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &byteSize) == noErr, byteSize > 0 else {
        return []
    }
    let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
    var objectIDs = Array(repeating: AudioObjectID(0), count: count)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteSize, &objectIDs) == noErr else {
        return []
    }
    return objectIDs.filter { $0 != 0 }
}

private func ownerObjectID(objectID: AudioObjectID) -> AudioObjectID? {
    guard let owner = try? uint32Property(objectID: objectID,
                                          selector: kAudioObjectPropertyOwner,
                                          scope: kAudioObjectPropertyScopeGlobal,
                                          element: kAudioObjectPropertyElementMain),
          owner != 0 else {
        return nil
    }
    return AudioObjectID(owner)
}

private func relatedObjectIDs(startingWith rootObjectID: AudioObjectID) -> [AudioObjectID] {
    var queue: [AudioObjectID] = [rootObjectID]
    var index = 0
    var seen = Set<AudioObjectID>()

    while index < queue.count {
        let objectID = queue[index]
        index += 1
        if objectID == 0 || seen.contains(objectID) {
            continue
        }
        seen.insert(objectID)

        for child in ownedObjectIDs(objectID: objectID) where !seen.contains(child) {
            queue.append(child)
        }
        if let owner = ownerObjectID(objectID: objectID), !seen.contains(owner) {
            queue.append(owner)
        }
    }

    return queue.filter { seen.contains($0) }
}

private let avidOpticalFormatSelector: AudioObjectPropertySelector = 0xFFFFFC0B
private let proprietaryOpticalFormats: [SelectorItemInfo] = [
    SelectorItemInfo(id: 0, name: "ADAT"),
    SelectorItemInfo(id: 1, name: "S/PDIF")
]
private let opticalHardwareConfigControlID: UInt32 = 0x48576366 // 'HWcf'
private let ioAudioDeviceClassName = "IOAudioDevice"
private let ioAudioControlIDKey = "IOAudioControlID"
private let ioAudioControlValueKey = "IOAudioControlValue"
private let ioAudioEngineGlobalUIDKey = "IOAudioEngineGlobalUniqueID"
private let ioAudioDeviceNameKey = "IOAudioDeviceName"
private let ioAudioDeviceShortNameKey = "IOAudioDeviceShortName"
private let ioAudioDeviceManufacturerNameKey = "IOAudioDeviceManufacturerName"
private let ioAudioDeviceModelIDKey = "IOAudioDeviceModelID"
private let maMainEngineUniqueIDKey = "MAMainEngineUniqueID"
private let ioClassKey = "IOClass"
private let ioKitAvidTokens = ["avid", "digi", "digidesign", "003", "002", "fw003", "00family"]

private func ioRegistryUInt32Property(entry: io_registry_entry_t, key: String) -> UInt32? {
    guard let property = IORegistryEntryCreateCFProperty(entry,
                                                         key as CFString,
                                                         kCFAllocatorDefault,
                                                         0)?.takeRetainedValue() else {
        return nil
    }
    guard CFGetTypeID(property) == CFNumberGetTypeID() else {
        return nil
    }

    let number = property as! CFNumber
    var value: Int32 = 0
    guard CFNumberGetValue(number, .sInt32Type, &value) else {
        return nil
    }
    return UInt32(bitPattern: value)
}

private func ioRegistryStringPropertySearchingParents(entry: io_registry_entry_t, key: String) -> String? {
    guard let property = IORegistryEntrySearchCFProperty(entry,
                                                         kIOServicePlane,
                                                         key as CFString,
                                                         kCFAllocatorDefault,
                                                         IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)) else {
        return nil
    }
    guard CFGetTypeID(property) == CFStringGetTypeID() else {
        return nil
    }
    return property as? String
}

private func ioRegistryStringProperty(entry: io_registry_entry_t, key: String) -> String? {
    guard let property = IORegistryEntryCreateCFProperty(entry,
                                                         key as CFString,
                                                         kCFAllocatorDefault,
                                                         0)?.takeRetainedValue() else {
        return nil
    }
    guard CFGetTypeID(property) == CFStringGetTypeID() else {
        return nil
    }
    return property as? String
}

private func normalizedIdentifier(_ text: String) -> String {
    return text.lowercased().filter { $0.isLetter || $0.isNumber }
}

private func hasAvidToken(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return ioKitAvidTokens.contains { lowered.contains($0) }
}

private func ioKitAudioDeviceScore(entry: io_registry_entry_t,
                                   deviceUID: String?,
                                   deviceName: String) -> Int {
    var score = 0
    let requestedName = deviceName.lowercased()
    if let registryName = ioRegistryStringProperty(entry: entry, key: ioAudioDeviceNameKey)
        ?? ioRegistryStringProperty(entry: entry, key: ioAudioDeviceShortNameKey) {
        let registryLower = registryName.lowercased()
        if !requestedName.isEmpty && (registryLower.contains(requestedName) || requestedName.contains(registryLower)) {
            score += 700
        }
        if hasAvidToken(registryLower) {
            score += 180
        }
    }

    if let uid = deviceUID, !uid.isEmpty {
        if let mainEngineUID = ioRegistryStringProperty(entry: entry, key: maMainEngineUniqueIDKey)
            ?? ioRegistryStringPropertySearchingParents(entry: entry, key: ioAudioEngineGlobalUIDKey) {
            if mainEngineUID == uid {
                score += 1000
            } else {
                let lhs = normalizedIdentifier(mainEngineUID)
                let rhs = normalizedIdentifier(uid)
                if !lhs.isEmpty && !rhs.isEmpty && (lhs.contains(rhs) || rhs.contains(lhs)) {
                    score += 450
                }
            }
        }
    }

    if let manufacturer = ioRegistryStringProperty(entry: entry, key: ioAudioDeviceManufacturerNameKey),
       hasAvidToken(manufacturer) {
        score += 160
    }

    if let modelID = ioRegistryStringProperty(entry: entry, key: ioAudioDeviceModelIDKey),
       hasAvidToken(modelID) {
        score += 220
    }

    if let ioClass = ioRegistryStringProperty(entry: entry, key: ioClassKey) {
        let lowered = ioClass.lowercased()
        if lowered == "com_digidesign_003audiodevice" {
            score += 280
        } else if hasAvidToken(lowered) {
            score += 150
        }
    }

    return score
}

private func findIOKitOpticalControlEntry(inSubtree root: io_registry_entry_t) -> io_registry_entry_t? {
    if let controlID = ioRegistryUInt32Property(entry: root, key: ioAudioControlIDKey),
       controlID == opticalHardwareConfigControlID,
       ioRegistryUInt32Property(entry: root, key: ioAudioControlValueKey) != nil {
        IOObjectRetain(root)
        return root
    }

    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(root, kIOServicePlane, &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }

    while true {
        let child = IOIteratorNext(iterator)
        if child == 0 {
            break
        }
        if let found = findIOKitOpticalControlEntry(inSubtree: child) {
            IOObjectRelease(child)
            return found
        }
        IOObjectRelease(child)
    }
    return nil
}

private func withIOKitOpticalControlEntry(deviceID: AudioDeviceID,
                                          _ body: (io_registry_entry_t) -> Bool) -> Bool {
    let deviceUID = try? cfStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    let deviceName = (try? cfStringProperty(deviceID, selector: kAudioObjectPropertyName)) ?? ""

    guard let matching = IOServiceMatching(ioAudioDeviceClassName) else {
        return false
    }

    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return false
    }
    defer { IOObjectRelease(iterator) }

    var bestControl: io_registry_entry_t = 0
    var bestScore = Int.min

    while true {
        let deviceEntry = IOIteratorNext(iterator)
        if deviceEntry == 0 {
            break
        }
        defer { IOObjectRelease(deviceEntry) }

        guard let controlEntry = findIOKitOpticalControlEntry(inSubtree: deviceEntry) else {
            continue
        }
        let score = ioKitAudioDeviceScore(entry: deviceEntry, deviceUID: deviceUID, deviceName: deviceName)
        if score > bestScore {
            if bestControl != 0 {
                IOObjectRelease(bestControl)
            }
            bestControl = controlEntry
            bestScore = score
        } else {
            IOObjectRelease(controlEntry)
        }
    }

    guard bestControl != 0 else {
        return false
    }
    defer { IOObjectRelease(bestControl) }
    return body(bestControl)
}

private func ioKitOpticalFormatControl(deviceID: AudioDeviceID) -> IOKitOpticalControlInfo? {
    var currentValue: UInt32?
    _ = withIOKitOpticalControlEntry(deviceID: deviceID) { entry in
        guard let value = ioRegistryUInt32Property(entry: entry, key: ioAudioControlValueKey) else {
            return false
        }
        currentValue = value
        return true
    }
    guard let currentValue else {
        return nil
    }
    return IOKitOpticalControlInfo(currentValue: currentValue)
}

private func setIOKitOpticalFormat(deviceID: AudioDeviceID, value: UInt32) -> Bool {
    return withIOKitOpticalControlEntry(deviceID: deviceID) { entry in
        var signedValue = Int32(bitPattern: value)
        guard let number = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &signedValue) else {
            return false
        }
        let status = IORegistryEntrySetCFProperty(entry, ioAudioControlValueKey as CFString, number)
        return status == KERN_SUCCESS
    }
}

private func proprietaryOpticalFormatProperty(deviceID: AudioDeviceID) throws -> ProprietaryOpticalPropertyInfo? {
    let candidates: [(AudioObjectPropertyScope, AudioObjectPropertyElement)] = [
        (kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain),
        (kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain),
        (kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain),
        (kAudioObjectPropertyScopeWildcard, kAudioObjectPropertyElementMain),
        (kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementWildcard),
        (kAudioObjectPropertyScopeWildcard, kAudioObjectPropertyElementWildcard),
        (kAudioObjectPropertyScopeGlobal, 0),
        (kAudioDevicePropertyScopeOutput, 0),
        (kAudioDevicePropertyScopeInput, 0),
        (kAudioObjectPropertyScopeWildcard, 0)
    ]

    var matches: [ProprietaryOpticalPropertyInfo] = []
    let objectIDs = relatedObjectIDs(startingWith: deviceID)

    for objectID in objectIDs {
        for (scope, element) in candidates {
            var address = AudioObjectPropertyAddress(mSelector: avidOpticalFormatSelector, mScope: scope, mElement: element)
            guard AudioObjectHasProperty(objectID, &address) else {
                continue
            }

            var byteSize: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &byteSize)
            guard sizeStatus == noErr, byteSize >= UInt32(MemoryLayout<UInt32>.size) else {
                continue
            }

            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            let readStatus = AudioObjectGetPropertyData(objectID, &address, 0, nil, &valueSize, &value)
            guard readStatus == noErr else {
                continue
            }

            var settable = DarwinBoolean(false)
            let settableStatus = AudioObjectIsPropertySettable(objectID, &address, &settable)
            let isSettable = (settableStatus == noErr) && settable.boolValue

            matches.append(ProprietaryOpticalPropertyInfo(objectID: objectID,
                                                          scope: scope,
                                                          element: element,
                                                          currentValue: value,
                                                          isSettable: isSettable))
        }
    }

    if matches.isEmpty {
        return nil
    }

    matches.sort { lhs, rhs in
        let lhsScore = (lhs.isSettable ? 100 : 0)
            + (lhs.objectID == deviceID ? 40 : 0)
            + (lhs.scope == kAudioObjectPropertyScopeGlobal ? 10 : 0)
            + (lhs.element == kAudioObjectPropertyElementMain ? 10 : 0)
        let rhsScore = (rhs.isSettable ? 100 : 0)
            + (rhs.objectID == deviceID ? 40 : 0)
            + (rhs.scope == kAudioObjectPropertyScopeGlobal ? 10 : 0)
            + (rhs.element == kAudioObjectPropertyElementMain ? 10 : 0)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return lhs.objectID < rhs.objectID
    }

    return matches.first
}

private func setProprietaryOpticalFormat(deviceID: AudioDeviceID,
                                         property: ProprietaryOpticalPropertyInfo,
                                         value: UInt32) throws {
    var address = AudioObjectPropertyAddress(mSelector: avidOpticalFormatSelector,
                                             mScope: property.scope,
                                             mElement: property.element)
    var payload = value
    let size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectSetPropertyData(property.objectID, &address, 0, nil, size, &payload)
    try checkStatus(status, "Set proprietary optical format")
}

private func selectorControlItemName(controlID: AudioObjectID,
                                     scope: AudioObjectPropertyScope,
                                     element: AudioObjectPropertyElement,
                                     itemID: UInt32) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioSelectorControlPropertyItemName,
        mScope: scope,
        mElement: element
    )

    var input = itemID
    var output: Unmanaged<CFString>? = nil
    var translation = withUnsafeMutablePointer(to: &input) { inputPtr in
        withUnsafeMutablePointer(to: &output) { outputPtr in
            AudioValueTranslation(
                mInputData: inputPtr,
                mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                mOutputData: outputPtr,
                mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            )
        }
    }
    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
    let status = AudioObjectGetPropertyData(controlID, &address, 0, nil, &size, &translation)
    if status == noErr, let output {
        return output.takeRetainedValue() as String
    }
    return "Item \(itemID)"
}

private func selectorControlInfo(controlID: AudioObjectID) -> SelectorControlInfo? {
    let scope = (try? uint32Property(objectID: controlID,
                                     selector: kAudioControlPropertyScope)) ?? kAudioObjectPropertyScopeGlobal
    let element = (try? uint32Property(objectID: controlID,
                                       selector: kAudioControlPropertyElement)) ?? kAudioObjectPropertyElementMain

    guard hasProperty(objectID: controlID,
                      selector: kAudioSelectorControlPropertyAvailableItems,
                      scope: scope,
                      element: element) else {
        return nil
    }
    guard hasProperty(objectID: controlID,
                      selector: kAudioSelectorControlPropertyCurrentItem,
                      scope: scope,
                      element: element) else {
        return nil
    }

    guard let currentItem = try? uint32Property(objectID: controlID,
                                                selector: kAudioSelectorControlPropertyCurrentItem,
                                                scope: scope,
                                                element: element),
          let itemIDs = try? uint32ArrayProperty(objectID: controlID,
                                                 selector: kAudioSelectorControlPropertyAvailableItems,
                                                 scope: scope,
                                                 element: element),
          !itemIDs.isEmpty else {
        return nil
    }

    let classID = (try? uint32Property(objectID: controlID,
                                       selector: kAudioObjectPropertyClass)) ?? 0
    let name = (try? cfStringProperty(controlID, selector: kAudioObjectPropertyName)) ?? "Control \(controlID)"
    let items = itemIDs.map { SelectorItemInfo(id: $0,
                                               name: selectorControlItemName(controlID: controlID,
                                                                             scope: scope,
                                                                             element: element,
                                                                             itemID: $0)) }
    return SelectorControlInfo(controlID: controlID,
                               classID: classID,
                               name: name,
                               scope: scope,
                               element: element,
                               currentItem: currentItem,
                               items: items)
}

private func normalizeLabel(_ label: String) -> String {
    let lowered = label.lowercased()
    return lowered.replacingOccurrences(of: " ", with: "")
                  .replacingOccurrences(of: "-", with: "")
                  .replacingOccurrences(of: "/", with: "")
}

private func isADATLabel(_ label: String) -> Bool {
    return normalizeLabel(label).contains("adat")
}

private func isSPDIFLabel(_ label: String) -> Bool {
    return normalizeLabel(label).contains("spdif")
}

private func opticalFormatControl(deviceID: AudioDeviceID) throws -> SelectorControlInfo? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyControlList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var byteSize: UInt32 = 0
    try checkStatus(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteSize),
                    "Get control-list size")
    if byteSize == 0 {
        return nil
    }

    let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
    var controlIDs = Array(repeating: AudioObjectID(0), count: count)
    try checkStatus(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteSize, &controlIDs),
                    "Get control-list")

    var candidates: [SelectorControlInfo] = []
    for controlID in controlIDs {
        guard controlID != 0, let info = selectorControlInfo(controlID: controlID) else {
            continue
        }
        let names = info.items.map(\.name)
        let hasADAT = names.contains(where: isADATLabel)
        let hasSPDIF = names.contains(where: isSPDIFLabel)
        if hasADAT && hasSPDIF {
            candidates.append(info)
        }
    }

    if candidates.isEmpty {
        return nil
    }

    candidates.sort { lhs, rhs in
        let lhsName = lhs.name.lowercased()
        let rhsName = rhs.name.lowercased()
        let lhsOptical = lhsName.contains("optical")
        let rhsOptical = rhsName.contains("optical")
        if lhsOptical != rhsOptical {
            return lhsOptical && !rhsOptical
        }

        let lhsClass = (lhs.classID == kAudioDataSourceControlClassID || lhs.classID == kAudioDataDestinationControlClassID)
        let rhsClass = (rhs.classID == kAudioDataSourceControlClassID || rhs.classID == kAudioDataDestinationControlClassID)
        if lhsClass != rhsClass {
            return lhsClass && !rhsClass
        }
        return lhs.controlID < rhs.controlID
    }

    return candidates.first
}

private func setSelectorControlItem(_ control: SelectorControlInfo, itemID: UInt32) throws {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioSelectorControlPropertyCurrentItem,
        mScope: control.scope,
        mElement: control.element
    )
    var value = itemID
    let size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectSetPropertyData(control.controlID, &address, 0, nil, size, &value)
    try checkStatus(status, "Set selector item")
}

private func availableSampleRates(deviceID: AudioDeviceID) throws -> [Double] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var byteSize: UInt32 = 0
    try checkStatus(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteSize),
                    "Get sample-rate size")

    let count = Int(byteSize) / MemoryLayout<AudioValueRange>.size
    var ranges = Array(repeating: AudioValueRange(), count: count)
    try checkStatus(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteSize, &ranges),
                    "Get sample-rate ranges")

    let canonicalRates: [Double] = [32000, 44100, 48000, 88200, 96000, 176400, 192000]
    var values = Set<Double>()
    for range in ranges {
        if abs(range.mMinimum - range.mMaximum) < 0.01 {
            values.insert(range.mMinimum)
            continue
        }
        for rate in canonicalRates where rate >= range.mMinimum && rate <= range.mMaximum {
            values.insert(rate)
        }
    }

    if values.isEmpty {
        values.insert(try currentSampleRate(deviceID: deviceID))
    }
    return values.sorted()
}

private func setSampleRate(deviceID: AudioDeviceID, rate: Double) throws {
    var value = Float64(rate)
    let size = UInt32(MemoryLayout<Float64>.size)
    var success = false
    var lastError: OSStatus = noErr

    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, // placeholder
        mElement: kAudioObjectPropertyElementMain
    )

    let scopes = [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeOutput, kAudioDevicePropertyScopeInput]

    for scope in scopes {
        addr.mScope = scope
        let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &value)
        if status == noErr {
            success = true
        } else {
            lastError = status
        }
    }

    if !success {
        try checkStatus(lastError, "Set sample rate")
    }
}

private func currentClockSource(deviceID: AudioDeviceID) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyClockSource,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var source = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source)
    try checkStatus(status, "Read current clock source")
    return source
}

private func clockSourceName(deviceID: AudioDeviceID, sourceID: UInt32) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyClockSourceNameForIDCFString,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var input = sourceID
    var output: Unmanaged<CFString>? = nil
    var translation = withUnsafeMutablePointer(to: &input) { inputPtr in
        withUnsafeMutablePointer(to: &output) { outputPtr in
            AudioValueTranslation(
                mInputData: inputPtr,
                mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                mOutputData: outputPtr,
                mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            )
        }
    }
    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &translation)
    if status == noErr, let output {
        return output.takeRetainedValue() as String
    }
    return "Source \(sourceID)"
}

private func availableClockSources(deviceID: AudioDeviceID) throws -> [ClockSourceInfo] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyClockSources,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var byteSize: UInt32 = 0
    try checkStatus(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteSize),
                    "Get clock-source size")

    let count = Int(byteSize) / MemoryLayout<UInt32>.size
    var sourceIDs = Array(repeating: UInt32(0), count: count)
    try checkStatus(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteSize, &sourceIDs),
                    "Get clock-source list")

    return sourceIDs.map { ClockSourceInfo(id: $0, name: clockSourceName(deviceID: deviceID, sourceID: $0)) }
}

private func setClockSource(deviceID: AudioDeviceID, sourceID: UInt32) throws {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyClockSource,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value = sourceID
    let size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
    try checkStatus(status, "Set clock source")
}

private func formatRate(_ rate: Double) -> String {
    if abs(rate.rounded() - rate) < 0.001 {
        return "\(Int(rate.rounded())) Hz"
    }
    return String(format: "%.2f Hz", rate)
}

private func deviceImageResourceName(for deviceName: String) -> String? {
    let name = deviceName.lowercased()
    let isRack = name.contains("rack")

    if name.contains("002") {
        return isRack ? "DIGI002_Rack" : "DIGI002_Console"
    }
    if name.contains("003") {
        return isRack ? "DIGI003_Rack" : "DIGI003_Console"
    }
    return nil
}

private final class ConnectionIndicatorView: NSView {
    private var connected = false

    override var isFlipped: Bool { false }

    func setConnected(_ connected: Bool) {
        guard self.connected != connected else { return }
        self.connected = connected
        needsDisplay = true
        setAccessibilityLabel(connected ? "Digi 002/003 connected" : "Digi 002/003 not connected")
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let box = NSRect(x: bounds.maxX - 80, y: bounds.minY, width: 80, height: bounds.height)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSColor(calibratedWhite: 0.42, alpha: 1).setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 10),
            .foregroundColor: connected
                ? NSColor(calibratedRed: 0.25, green: 0.76, blue: 0.36, alpha: 1)
                : NSColor(calibratedWhite: 0.60, alpha: 1)
        ]
        let text = "CONNECTED"
        let textSize = (text as NSString).size(withAttributes: textAttributes)
        let textRect = NSRect(
            x: box.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: textAttributes)

        let deviceText = "Digi 002/003"
        let deviceAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let deviceSize = (deviceText as NSString).size(withAttributes: deviceAttributes)
        let deviceRect = NSRect(
            x: box.minX - 8 - deviceSize.width,
            y: textRect.origin.y,
            width: deviceSize.width,
            height: textSize.height
        )
        (deviceText as NSString).draw(in: deviceRect, withAttributes: deviceAttributes)
    }
}

final class PanelController: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let statusLabel = NSTextField(labelWithString: "")
    private let deviceNameLabel = NSTextField(labelWithString: "None")
    private let deviceImageView = NSImageView()
    private let sampleRatePopup = NSPopUpButton()
    private let opticalFormatPopup = NSPopUpButton()
    private let clockSourcePopup = NSPopUpButton()
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let connectionIndicator = ConnectionIndicatorView()
    private var connectionTimer: Timer?

    private var devices: [DeviceInfo] = []
    private var sampleRates: [Double] = []
    private var clockSources: [ClockSourceInfo] = []
    private var opticalControl: SelectorControlInfo?
    private var ioKitOpticalControl: IOKitOpticalControlInfo?
    private var proprietaryOpticalProperty: ProprietaryOpticalPropertyInfo?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        reloadAll()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollForDeviceChanges()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        connectionTimer?.invalidate()
    }

    @objc private func reloadAll() {
        do {
            devices = try findDevices()
            updateConnectionStatus()
            if devices.isEmpty {
                deviceNameLabel.stringValue = "None"
                deviceImageView.image = nil
                deviceImageView.isHidden = true
                setStatus("No Avid Digi 002/003 device connected.")
                clearDeviceControls()
                return
            }
            deviceNameLabel.stringValue = devices[0].name
            updateDeviceImage(for: devices[0].name)
            try reloadForCurrentDevice()
            setStatus("Ready.")
        } catch {
            setStatus("Error: \(errorDescription(error))")
        }
    }

    @objc private func sampleRateChanged() {
        guard let deviceID = selectedDeviceID else { return }
        let index = sampleRatePopup.indexOfSelectedItem
        guard index >= 0 && index < sampleRates.count else { return }

        do {
            try setSampleRate(deviceID: deviceID, rate: sampleRates[index])
            try reloadForCurrentDevice()
            setStatus("Sample rate updated.")
        } catch {
            setStatus("Set sample rate failed: \(errorDescription(error))")
        }
    }

    @objc private func clockSourceChanged() {
        guard let deviceID = selectedDeviceID else { return }
        let index = clockSourcePopup.indexOfSelectedItem
        guard index >= 0 && index < clockSources.count else { return }

        do {
            try setClockSource(deviceID: deviceID, sourceID: clockSources[index].id)
            try reloadForCurrentDevice()
            setStatus("Clock source updated.")
        } catch {
            setStatus("Set clock source failed: \(errorDescription(error))")
        }
    }

    @objc private func opticalFormatChanged() {
        let index = opticalFormatPopup.indexOfSelectedItem
        guard index >= 0 else { return }

        if ioKitOpticalControl != nil, let deviceID = selectedDeviceID {
            guard index < proprietaryOpticalFormats.count else { return }
            do {
                let didSet = setIOKitOpticalFormat(deviceID: deviceID,
                                                   value: proprietaryOpticalFormats[index].id)
                try checkStatus(didSet ? noErr : OSStatus(-1), "Set IORegistry optical format")
                try reloadForCurrentDevice()
                setStatus("Optical format updated.")
            } catch {
                setStatus("Set optical format failed: \(errorDescription(error))")
            }
            return
        }

        if let deviceID = selectedDeviceID, let property = proprietaryOpticalProperty {
            guard index < proprietaryOpticalFormats.count else { return }
            do {
                try setProprietaryOpticalFormat(deviceID: deviceID,
                                                property: property,
                                                value: proprietaryOpticalFormats[index].id)
                try reloadForCurrentDevice()
                setStatus("Optical format updated.")
            } catch {
                setStatus("Set optical format failed: \(errorDescription(error))")
            }
            return
        }

        guard let control = opticalControl, index < control.items.count else { return }
        do {
            try setSelectorControlItem(control, itemID: control.items[index].id)
            try reloadForCurrentDevice()
            setStatus("Optical format updated.")
        } catch {
            setStatus("Set optical format failed: \(errorDescription(error))")
        }
    }

    private var selectedDeviceID: AudioDeviceID? {
        return devices.first?.id
    }

    private func reloadForCurrentDevice() throws {
        guard let deviceID = selectedDeviceID else { return }

        sampleRatePopup.isEnabled = true
        clockSourcePopup.isEnabled = true

        sampleRates = try availableSampleRates(deviceID: deviceID)
        let currentRate = try currentSampleRate(deviceID: deviceID)
        sampleRatePopup.removeAllItems()
        for rate in sampleRates {
            sampleRatePopup.addItem(withTitle: formatRate(rate))
        }
        if let idx = sampleRates.firstIndex(where: { abs($0 - currentRate) < 0.1 }) {
            sampleRatePopup.selectItem(at: idx)
        }

        ioKitOpticalControl = ioKitOpticalFormatControl(deviceID: deviceID)
        proprietaryOpticalProperty = nil
        opticalControl = nil
        opticalFormatPopup.removeAllItems()
        if let ioKitControl = ioKitOpticalControl {
            for item in proprietaryOpticalFormats {
                opticalFormatPopup.addItem(withTitle: item.name)
            }
            if let idx = proprietaryOpticalFormats.firstIndex(where: { $0.id == ioKitControl.currentValue }) {
                opticalFormatPopup.selectItem(at: idx)
            } else {
                opticalFormatPopup.addItem(withTitle: "Value \(ioKitControl.currentValue)")
                opticalFormatPopup.selectItem(at: proprietaryOpticalFormats.count)
            }
            opticalFormatPopup.isEnabled = true
        } else if let property = try proprietaryOpticalFormatProperty(deviceID: deviceID) {
            proprietaryOpticalProperty = property
            for item in proprietaryOpticalFormats {
                opticalFormatPopup.addItem(withTitle: item.name)
            }
            if let idx = proprietaryOpticalFormats.firstIndex(where: { $0.id == property.currentValue }) {
                opticalFormatPopup.selectItem(at: idx)
            } else {
                opticalFormatPopup.addItem(withTitle: "Value \(property.currentValue)")
                opticalFormatPopup.selectItem(at: proprietaryOpticalFormats.count)
            }
            opticalFormatPopup.isEnabled = property.isSettable
        } else if let control = try opticalFormatControl(deviceID: deviceID) {
            opticalControl = control
            for item in control.items {
                opticalFormatPopup.addItem(withTitle: item.name)
            }
            if let idx = control.items.firstIndex(where: { $0.id == control.currentItem }) {
                opticalFormatPopup.selectItem(at: idx)
            }
            opticalFormatPopup.isEnabled = true
        } else {
            opticalFormatPopup.addItem(withTitle: "Unavailable")
            opticalFormatPopup.selectItem(at: 0)
            opticalFormatPopup.isEnabled = false
        }

        clockSources = try availableClockSources(deviceID: deviceID)
        let currentSource = try currentClockSource(deviceID: deviceID)
        clockSourcePopup.removeAllItems()
        for source in clockSources {
            clockSourcePopup.addItem(withTitle: source.name)
        }
        if let idx = clockSources.firstIndex(where: { $0.id == currentSource }) {
            clockSourcePopup.selectItem(at: idx)
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func updateDeviceImage(for deviceName: String) {
        guard let resourceName = deviceImageResourceName(for: deviceName),
              let resourceURL = Bundle.main.url(forResource: resourceName, withExtension: "png"),
              let image = NSImage(contentsOf: resourceURL) else {
            deviceImageView.image = nil
            deviceImageView.isHidden = true
            return
        }
        deviceImageView.image = image
        // Console photos are taller than the rack photos, so give them a little
        // more vertical room in the same upper-right void.
        deviceImageView.frame = resourceName.contains("Console")
            ? NSRect(x: 365, y: 48, width: 235, height: 120)
            : NSRect(x: 350, y: 69, width: 250, height: 84)
        deviceImageView.isHidden = false
        deviceImageView.setAccessibilityLabel("Image of \(deviceName)")
    }

    private func clearDeviceControls() {
        sampleRatePopup.removeAllItems()
        opticalFormatPopup.removeAllItems()
        clockSourcePopup.removeAllItems()
        sampleRatePopup.isEnabled = false
        opticalFormatPopup.isEnabled = false
        clockSourcePopup.isEnabled = false
    }

    private func updateConnectionStatus() {
        // This is deliberately the same list displayed in the Avid Device field.
        connectionIndicator.setConnected(!devices.isEmpty)
    }

    private func pollForDeviceChanges() {
        guard let discoveredDevices = try? findDevices() else { return }
        if discoveredDevices.map(\.id) != devices.map(\.id) {
            reloadAll()
        }
    }

    private func buildUI() {
        NSApp.setActivationPolicy(.regular)
        
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu
        
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        let appName = ProcessInfo.processInfo.processName
        
        let hideItem = NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)
        
        appMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Digi 003 Family Control Panel (64-bit)"
        window.center()

        guard let content = window.contentView else {
            return
        }

        let title = NSTextField(labelWithString: "Digi 002/003 Control Panel")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        title.frame = NSRect(x: 20, y: 196, width: 460, height: 24)

        let deviceLabel = NSTextField(labelWithString: "Avid Device:")
        deviceLabel.frame = NSRect(x: 20, y: 156, width: 110, height: 24)
        deviceNameLabel.frame = NSRect(x: 140, y: 156, width: 300, height: 24)

        let sampleLabel = NSTextField(labelWithString: "Sample Rate:")
        sampleLabel.frame = NSRect(x: 20, y: 116, width: 110, height: 24)
        sampleRatePopup.frame = NSRect(x: 140, y: 112, width: 180, height: 30)
        sampleRatePopup.target = self
        sampleRatePopup.action = #selector(sampleRateChanged)

        let opticalLabel = NSTextField(labelWithString: "Optical Format:")
        opticalLabel.frame = NSRect(x: 20, y: 76, width: 110, height: 24)
        opticalFormatPopup.frame = NSRect(x: 140, y: 72, width: 180, height: 30)
        opticalFormatPopup.target = self
        opticalFormatPopup.action = #selector(opticalFormatChanged)

        let clockLabel = NSTextField(labelWithString: "Clock Source:")
        clockLabel.frame = NSRect(x: 20, y: 36, width: 110, height: 24)
        clockSourcePopup.frame = NSRect(x: 140, y: 32, width: 180, height: 30)
        clockSourcePopup.target = self
        clockSourcePopup.action = #selector(clockSourceChanged)

        refreshButton.frame = NSRect(x: 530, y: 192, width: 70, height: 30)
        refreshButton.target = self
        refreshButton.action = #selector(reloadAll)
        refreshButton.bezelStyle = .rounded

        statusLabel.frame = NSRect(x: 20, y: 8, width: 300, height: 20)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 1

        connectionIndicator.frame = NSRect(x: 408, y: 8, width: 192, height: 20)
        connectionIndicator.wantsLayer = true
        connectionIndicator.setAccessibilityElement(true)
        connectionIndicator.setAccessibilityRole(.staticText)
        connectionIndicator.setConnected(false)

        // This is the original panel's unused upper-right area.  It keeps every
        // image compact while preserving its original aspect ratio.
        deviceImageView.frame = NSRect(x: 350, y: 63, width: 250, height: 84)
        deviceImageView.imageScaling = .scaleProportionallyUpOrDown
        deviceImageView.imageAlignment = .alignCenter
        deviceImageView.setAccessibilityElement(true)
        deviceImageView.setAccessibilityRole(.image)
        deviceImageView.isHidden = true

        [title, deviceLabel, deviceNameLabel, sampleLabel, sampleRatePopup, opticalLabel, opticalFormatPopup, clockLabel, clockSourcePopup, refreshButton, statusLabel, connectionIndicator, deviceImageView]
            .forEach { content.addSubview($0) }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func errorDescription(_ error: Error) -> String {
        if case let AudioError.osStatus(status, context) = error {
            return "\(context) (OSStatus \(status))"
        }
        return error.localizedDescription
    }
}

let app = NSApplication.shared
let delegate = PanelController()
app.delegate = delegate
app.run()
