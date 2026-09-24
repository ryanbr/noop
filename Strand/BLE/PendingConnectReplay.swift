import Foundation

/// What a central should do when `centralManagerDidUpdateState` reports `.poweredOn` and a connect
/// intent was parked because the radio was not up yet.
///
/// `retrievePeripherals(withIdentifiers:)` answers nothing before `.poweredOn`. Every source read that
/// empty answer as "this device has never been seen here" and took the discovery branch: park the id,
/// start a service-filtered scan. The replay on `.poweredOn` then looked the id up in `seenPeripherals`
/// only, which is empty for the same reason, so it fell through to the scan it had just armed. The
/// targeted `central.connect` that CoreBluetooth honours while the app is suspended was never issued.
///
/// In the foreground that costs nothing, because a scan finds the device in seconds. In the background
/// iOS throttles scanning hard: the #2433 report has a ring that had been bonded to the phone for weeks
/// found 29 min 54 s after a background relaunch, on a night when the WHOOP central beside it attached
/// immediately. `BLEManager` learned this for straps in #2272 ("a background scan would not find it")
/// and connects by identifier off-screen; the four peripheral sources never did.
///
/// Asking again once the radio IS up is what separates the two meanings of an empty retrieve, so the
/// replay below is a function of whether the id was already held, whether the fresh retrieve found it,
/// and whether a scan was wanted anyway.
enum PendingConnect {

    /// The action a `.poweredOn` transition should take for a parked connect.
    enum Replay: Equatable {
        /// A peripheral object is in hand: issue the targeted connect.
        case connect
        /// No peripheral to connect, and a scan was already armed and waiting on the radio: start it.
        case scan
        /// A parked connect for a device this phone cannot resolve: arm discovery and connect on sight.
        case discover
        /// Nothing outstanding.
        case idle
    }

    /// Decide the replay from the four facts that drive it.
    ///
    /// Deliberately free of CoreBluetooth so the decision can be tested without a radio, a peripheral or
    /// a `CBCentralManager`: the hardware proof is a background relaunch followed within seconds by a
    /// connect line rather than a scan, which no unit test can stage.
    ///
    /// - Parameters:
    ///   - isPending: a connect was parked before the radio was ready.
    ///   - isHeld: the id is already in `seenPeripherals`.
    ///   - didRetrieve: a retrieve issued NOW, with the radio up, found the peripheral.
    ///   - isScanning: a scan was requested and is waiting on the radio.
    static func replay(isPending: Bool, isHeld: Bool, didRetrieve: Bool, isScanning: Bool) -> Replay {
        guard isPending else { return isScanning ? .scan : .idle }
        // Either source of a peripheral object is enough, and the retrieve is the one that used to be
        // missing: it is the whole point of re-asking now that the state is `.poweredOn`.
        if isHeld || didRetrieve { return .connect }
        // Genuinely unknown to this device, so discovery is the only way to acquire a handle. It must be
        // ARMED here, not merely resumed: parking the intent before the retrieve means nothing called
        // `scan()` on the way past, so there is no deferred scan waiting to be picked up. Returning
        // `.idle` instead would strand a connect asked for before the radio was up, which is how a
        // first-ever pairing arrives.
        return isScanning ? .scan : .discover
    }
}
