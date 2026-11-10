import CoreBluetooth
import Foundation

/// The Mac's side of the BLE link: advertises the bleping service all the time, takes
/// pairing writes from the iPhone, and pushes (already encrypted) events to it.
final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    /// A pairing message arrived from an iPhone.
    var onPairingMessage: ((Data, CBCentral) -> Void)?
    /// Bluetooth turned on/off or permission changed.
    var onStateChange: ((CBManagerState) -> Void)?
    /// An iPhone subscribed to or left the events characteristic.
    var onSubscribersChanged: (() -> Void)?

    private var manager: CBPeripheralManager!
    private var pairingChar: CBMutableCharacteristic?
    private var eventsChar: CBMutableCharacteristic?
    private var serviceAdded = false
    /// Packets waiting for room in CoreBluetooth's send queue.
    private var outbox: [(packet: Data, characteristic: CBMutableCharacteristic, to: [CBCentral]?)] = []
    private var chunkTag: UInt8 = 0
    /// iPhones that proved they hold the pairing key on this connection. Only these get events.
    private var trusted: Set<UUID> = []

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    /// Checked iPhones listening for events. Other devices in range don't count.
    var connectedPhones: Int { phones.count }

    private var phones: [CBCentral] {
        (eventsChar?.subscribedCentrals ?? []).filter { trusted.contains($0.identifier) }
    }

    /// This iPhone proved it holds the pairing key: send it events from now on.
    func trust(_ central: CBCentral) {
        trusted.insert(central.identifier)
        onSubscribersChanged?()
    }

    func isTrusted(_ central: CBCentral) -> Bool { trusted.contains(central.identifier) }

    /// The pairing changed: every iPhone has to pass the check again.
    func untrustAll() {
        trusted.removeAll()
        outbox.removeAll { $0.characteristic === eventsChar }
        onSubscribersChanged?()
    }

    func sendPairing(_ message: PairMessage, to central: CBCentral) {
        guard let pairingChar else { return }
        outbox.append((message.encoded, pairingChar, [central]))
        flush()
    }

    /// Sends one sealed event to every checked iPhone, or just to `central` if it's checked.
    /// Each gets chunks sized for its own connection, so one device can't shrink them for all.
    func sendEvent(_ sealed: Data, to central: CBCentral? = nil) {
        guard let eventsChar else { return }
        let targets = central.map { [$0].filter(isTrusted) } ?? phones
        guard !targets.isEmpty else { return }
        chunkTag &+= 1
        for target in targets {
            guard let chunks = Chunker.split(sealed, tag: chunkTag, maxPacket: target.maximumUpdateValueLength) else {
                log("Notification too large to send (\(sealed.count) bytes)")
                continue
            }
            for chunk in chunks { outbox.append((chunk, eventsChar, [target])) }
        }
        flush()
    }

    private func flush() {
        while let next = outbox.first {
            guard manager.updateValue(next.packet, for: next.characteristic, onSubscribedCentrals: next.to) else {
                return   // queue full; peripheralManagerIsReady(toUpdateSubscribers:) calls us again
            }
            outbox.removeFirst()
        }
    }

    private func setUpService() {
        guard !serviceAdded else { return }
        serviceAdded = true
        let pairing = CBMutableCharacteristic(type: Wire.pairingUUID, properties: [.write, .notify],
                                              value: nil, permissions: [.writeable])
        let events = CBMutableCharacteristic(type: Wire.eventsUUID, properties: [.notify],
                                             value: nil, permissions: [])
        let service = CBMutableService(type: Wire.serviceUUID, primary: true)
        service.characteristics = [pairing, events]
        pairingChar = pairing
        eventsChar = events
        // macOS can keep a published service across a Bluetooth off/on. Adding ours again
        // would leave two copies: the iPhone subscribes to the old one while we send on the new.
        manager.stopAdvertising()
        manager.removeAllServices()
        manager.add(service)
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log("Bluetooth: \(peripheral.state.label)")
        if peripheral.state != .poweredOn {
            // macOS drops our service (and every connection) when Bluetooth goes off, so set
            // it up again from scratch when it comes back.
            serviceAdded = false
            pairingChar = nil
            eventsChar = nil
            outbox.removeAll()
            trusted.removeAll()
        }
        onStateChange?(peripheral.state)
        switch peripheral.state {
        case .poweredOn:
            setUpService()
        case .unauthorized:
            log("Allow Bluetooth for bleping (or the terminal running it) in System Settings › Privacy & Security › Bluetooth")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log("Could not set up the Bluetooth service: \(error.localizedDescription)")
            return
        }
        // Only the service UUID, which the iPhone needs to find the Mac in the background. No
        // name: there's no need to tell everyone nearby that this is a bleping Mac.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Wire.serviceUUID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            log("Advertising failed: \(error.localizedDescription)")
        } else {
            log("Visible to the iPhone app")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // Nothing is readable: the iPhone finds its Mac by challenging it (see Wire.swift).
        peripheral.respond(to: request, withResult: .requestNotSupported)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard requests.allSatisfy({ $0.characteristic.uuid == Wire.pairingUUID }) else {
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            if let value = request.value {
                if ProcessInfo.processInfo.environment["BLEPING_DEBUG"] != nil {
                    log("debug: pairing message 0x\(String(format: "%02x", value.first ?? 0)) (\(value.count) bytes)")
                }
                onPairingMessage?(value, request.central)
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == Wire.pairingUUID { log("An iPhone connected") }
        if characteristic.uuid == Wire.eventsUUID {
            if isTrusted(central) {
                log("iPhone connected (\(connectedPhones) listening\(characteristic === eventsChar ? "" : ", to an old copy of the service!"))")
            } else {
                log("A device that didn't pass the check subscribed; it gets nothing")
            }
            onSubscribersChanged?()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == Wire.eventsUUID, isTrusted(central) {
            trusted.remove(central.identifier)
            log("iPhone disconnected (\(connectedPhones) listening)")
        }
        // Gone from either characteristic means gone: it has to pass the check again.
        trusted.remove(central.identifier)
        onSubscribersChanged?()
        outbox.removeAll { $0.to?.contains(central) == true }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flush()
    }
}

extension CBManagerState {
    var label: String {
        switch self {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "state \(rawValue)"
        }
    }
}
