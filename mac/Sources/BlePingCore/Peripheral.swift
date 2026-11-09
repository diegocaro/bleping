import CoreBluetooth
import Foundation

/// The Mac's side of the BLE link: advertises the bleping service all the time, takes
/// pairing writes from the iPhone, and pushes (already encrypted) events to it.
final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    /// A pairing message arrived from an iPhone.
    var onPairingMessage: ((Data, CBCentral) -> Void)?
    /// An iPhone subscribed to events (it has checked this is its Mac): time to replay.
    var onEventsSubscribed: ((CBCentral) -> Void)?
    /// Bluetooth turned on/off or permission changed.
    var onStateChange: ((CBManagerState) -> Void)?
    /// An iPhone subscribed to or left the events characteristic.
    var onSubscribersChanged: (() -> Void)?
    /// Served on the pairing-ID characteristic. Empty when nothing is paired.
    var pairingID = Data()

    private var manager: CBPeripheralManager!
    private var pairingChar: CBMutableCharacteristic?
    private var eventsChar: CBMutableCharacteristic?
    private var serviceAdded = false
    /// Packets waiting for room in CoreBluetooth's send queue.
    private var outbox: [(packet: Data, characteristic: CBMutableCharacteristic, to: [CBCentral]?)] = []
    private var chunkTag: UInt8 = 0

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    var connectedPhones: Int { eventsChar?.subscribedCentrals?.count ?? 0 }

    func sendPairing(_ message: PairMessage, to central: CBCentral) {
        guard let pairingChar else { return }
        outbox.append((message.encoded, pairingChar, [central]))
        flush()
    }

    /// Sends one sealed event to every subscribed iPhone, or just to `central`.
    func sendEvent(_ sealed: Data, to central: CBCentral? = nil) {
        guard let eventsChar else { return }
        let targets = central.map { [$0] } ?? eventsChar.subscribedCentrals ?? []
        guard !targets.isEmpty else { return }
        let maxPacket = targets.map(\.maximumUpdateValueLength).min() ?? 20
        chunkTag &+= 1
        guard let chunks = Chunker.split(sealed, tag: chunkTag, maxPacket: maxPacket) else {
            log("Notification too large to send (\(sealed.count) bytes)")
            return
        }
        for chunk in chunks { outbox.append((chunk, eventsChar, central.map { [$0] })) }
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
        let id = CBMutableCharacteristic(type: Wire.pairingIDUUID, properties: [.read],
                                         value: nil, permissions: [.readable])
        let service = CBMutableService(type: Wire.serviceUUID, primary: true)
        service.characteristics = [pairing, events, id]
        pairingChar = pairing
        eventsChar = events
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
        // The name fits in the main advertising packet next to the 128-bit service UUID.
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: Wire.advertisedName,
            CBAdvertisementDataServiceUUIDsKey: [Wire.serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            log("Advertising failed: \(error.localizedDescription)")
        } else {
            log("Visible to the iPhone app (advertising \"\(Wire.advertisedName)\")")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Wire.pairingIDUUID else {
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }
        guard request.offset <= pairingID.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = pairingID.subdata(in: request.offset ..< pairingID.count)
        peripheral.respond(to: request, withResult: .success)
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
        if characteristic.uuid == Wire.pairingUUID { log("An iPhone connected to pair") }
        if characteristic.uuid == Wire.eventsUUID {
            log("iPhone connected")
            onEventsSubscribed?(central)
            onSubscribersChanged?()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if characteristic.uuid == Wire.eventsUUID {
            log("iPhone disconnected")
            onSubscribersChanged?()
        }
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
