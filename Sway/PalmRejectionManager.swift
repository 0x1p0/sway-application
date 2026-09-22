import Foundation

// Observable evidence, not a "palm probability": identity, touchdown position,
// exact count, elapsed time, axis displacement, path efficiency and typing.
enum GestureRegion: String, CaseIterable {
    case none, left, right, topLeft, topRight, top
    var isTop: Bool { self == .top || self == .topLeft || self == .topRight }
}

struct GestureContact {
    let id: Int32
    let x: Double
    let y: Double
}

struct GestureInputFrame {
    let contacts: [GestureContact]
    let timestamp: Double
    let generation: UInt64
}

/// One scheduled main-queue delivery instead of a closure for every native
/// sample. Preserve ALL samples (including transient extra fingers and lifts).
/// If the UI stalls long enough to overflow, fail closed until a real full lift;
/// dropping intermediate positions must never make unsafe motion look valid.
final class GestureFrameInbox {
    private let lock = NSLock()
    private let capacity: Int
    private var frames: [GestureInputFrame] = []
    private var deliveryScheduled = false
    private var waitingForLift = false
    private var generation: UInt64?

    init(capacity: Int = 64) { self.capacity = max(2, capacity) }

    @discardableResult
    func enqueue(_ frame: GestureInputFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if generation != frame.generation {
            frames.removeAll(keepingCapacity: true)
            waitingForLift = false
            generation = frame.generation
        }
        if waitingForLift {
            guard frame.contacts.isEmpty else { return false }
            waitingForLift = false
            frames.append(frame)
        } else if frames.count >= capacity {
            frames.removeAll(keepingCapacity: true)
            frames.append(GestureInputFrame(contacts: [GestureContact(id: -1, x: .nan, y: .nan)],
                                            timestamp: frame.timestamp, generation: frame.generation))
            waitingForLift = !frame.contacts.isEmpty
            if frame.contacts.isEmpty { frames.append(frame) }
        } else {
            frames.append(frame)
        }
        guard !deliveryScheduled else { return false }
        deliveryScheduled = true
        return true
    }

    func takeBatch() -> [GestureInputFrame] {
        lock.lock()
        defer { lock.unlock() }
        let result = frames
        frames = []
        deliveryScheduled = false
        return result
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll(keepingCapacity: true)
        deliveryScheduled = false
        waitingForLift = false
        generation = nil
    }
}

struct GestureConfiguration: Equatable {
    var requiredFingers = 2
    var leftWidth = 0.2
    var rightWidth = 0.2
    var topHeight = 0.15
    var topEnabled = false
    var topHorizontal = true
    var enabledRegions: Set<GestureRegion> = [.left, .right, .topLeft, .topRight, .top]
    var strict = false
    var activationThreshold = 4.0
    var typingCooldown = 0.45

    var minimumLifetime: Double { strict ? 0.095 : 0.065 }
    var minimumSamples: Int { strict ? 6 : 4 }
    var minimumDisplacement: Double {
        max(strict ? 0.014 : 0.008, activationThreshold / 500 * (strict ? 1.3 : 1))
    }
    var requiredStraightness: Double { strict ? 0.85 : 0.72 }
    var restingDeadline: Double { strict ? 0.3 : 0.4 }

    func region(x: Double, y: Double) -> GestureRegion {
        let candidate: GestureRegion
        if topEnabled && y >= 1 - topHeight {
            candidate = topHorizontal ? (x < 0.5 ? .topLeft : .topRight) : .top
        } else if x <= leftWidth {
            candidate = .left
        } else if x >= 1 - rightWidth {
            candidate = .right
        } else {
            candidate = .none
        }
        return enabledRegions.contains(candidate) ? candidate : .none
    }
}

struct GestureDecision {
    enum Phase: String { case ready = "Ready", gathering = "Gathering", accepted = "Accepted", rejected = "Rejected" }
    var phase: Phase = .ready
    var reason = "Start at an enabled edge, then swipe."
    var region: GestureRegion = .none
    var x = 0.5
    var y = 0.5
    var count = 0
    var displacement = 0.0
    var straightness = 0.0
    var elapsed = 0.0
    var samples = 0
    var delta = 0.0
    var justAccepted = false
    var justRejected = false
    var ended = false
}

/// Deterministic and independent of AppKit, timers, controllers and wall-clock time.
/// A rejected contact stays rejected until EVERY finger lifts.
struct EdgeGestureRecognizer {
    private(set) var decision = GestureDecision()
    private var configuration = GestureConfiguration()
    private var startedAt: Double?
    private var assembledAt: Double?
    private var previousTime: Double?
    private var lastKeyTime = -Double.infinity
    private var firstPositions: [Int32: GestureContact] = [:]
    private var previousPositions: [Int32: GestureContact] = [:]
    private var pathLengths: [Int32: Double] = [:]
    private var assembledIDs: Set<Int32>?

    var isCapturing: Bool { startedAt != nil && !decision.ended && (decision.phase == .gathering || decision.phase == .accepted) }

    mutating func reset() { self = EdgeGestureRecognizer() }

    mutating func cancel(reason: String) -> GestureDecision {
        decision.delta = 0
        decision.justAccepted = false
        decision.justRejected = false
        if startedAt != nil && !decision.ended { reject(reason) }
        return decision
    }

    mutating func keyDown(at timestamp: Double) -> GestureDecision {
        lastKeyTime = timestamp
        return cancel(reason: "Typing detected. Lift your fingers, then try again.")
    }

    mutating func process(contacts: [GestureContact], timestamp: Double,
                          configuration newConfiguration: GestureConfiguration) -> GestureDecision {
        decision.delta = 0
        decision.justAccepted = false
        decision.justRejected = false
        decision.count = contacts.count
        guard !contacts.isEmpty else {
            let keyTime = lastKeyTime
            let previous = decision
            self = EdgeGestureRecognizer()
            lastKeyTime = keyTime
            // Preserve the last verdict after lift so the Test tab can explain it.
            decision = previous
            decision.count = 0
            decision.delta = 0
            decision.justAccepted = false
            decision.justRejected = false
            if previous.phase == .gathering {
                decision.phase = .rejected
                decision.reason = "Lifted before there was enough movement evidence."
                decision.justRejected = true
            }
            return decision
        }
        // Ordinary pointer use and a rejected palm can generate hundreds of
        // samples. Once blocked, only a physical full lift can change the
        // verdict; do not rebuild sets/dictionaries for those samples.
        if startedAt != nil && (decision.phase == .rejected || decision.ended) { return decision }
        let ids = Set(contacts.map(\.id))
        guard timestamp.isFinite,
              contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              ids.count == contacts.count else {
            if startedAt == nil { startedAt = timestamp.isFinite ? timestamp : 0 }
            reject("Invalid touch data. Lift your fingers to reset.")
            return decision
        }
        let count = Double(contacts.count)
        decision.x = contacts.reduce(0) { $0 + $1.x } / count
        decision.y = contacts.reduce(0) { $0 + $1.y } / count
        if startedAt == nil {
            configuration = newConfiguration
            startedAt = timestamp
            previousTime = timestamp
            decision = GestureDecision(phase: .gathering, reason: "Checking touch direction and movement…",
                                       x: decision.x, y: decision.y, count: contacts.count)
            decision.region = configuration.region(x: contacts[0].x, y: contacts[0].y)
            firstPositions = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
            previousPositions = firstPositions
            pathLengths = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, 0) })
            if decision.region == .none {
                reject("Touch started outside an enabled edge. Lift, then start at an edge.")
            }
        }
        decision.elapsed = max(0, timestamp - (startedAt ?? timestamp))
        guard decision.phase != .rejected && !decision.ended else { return decision }
        guard configuration == newConfiguration else {
            reject("Gesture settings changed. Lift your fingers to use the new setup.")
            return decision
        }
        guard timestamp - lastKeyTime >= configuration.typingCooldown else {
            reject("Typing cooldown is active. Lift your fingers, then try again.")
            return decision
        }
        guard contacts.count <= configuration.requiredFingers else {
            reject("Extra contact detected. Lift all fingers to reset.")
            return decision
        }
        if let assembledIDs, assembledIDs != ids {
            if decision.phase == .accepted && ids.isStrictSubset(of: assembledIDs) {
                // A normal two-finger release is often staggered by a scan. End
                // control immediately without labelling a successful swipe a palm.
                decision.ended = true
                decision.reason = "Gesture complete. Lift the remaining finger to reset."
                return decision
            }
            reject("Finger count or identity changed. Lift all fingers to reset.")
            return decision
        }
        // Allow a second finger to land within 100 ms, preserving the first
        // finger's true touchdown region and identity throughout assembly.
        if assembledIDs == nil {
            guard Set(firstPositions.keys).isSubset(of: ids) else {
                reject("A contact was replaced before the gesture began.")
                return decision
            }
            for contact in contacts where firstPositions[contact.id] == nil {
                firstPositions[contact.id] = contact
                previousPositions[contact.id] = contact
                pathLengths[contact.id] = 0
            }
            guard firstPositions.values.allSatisfy({ configuration.region(x: $0.x, y: $0.y) == decision.region }) else {
                reject("Both fingers must start in the same edge zone.")
                return decision
            }
            if contacts.count < configuration.requiredFingers {
                if decision.elapsed > 0.1 {
                    reject("This setup needs \(configuration.requiredFingers) fingers. Lift and try again.")
                } else {
                    decision.reason = "Waiting for \(configuration.requiredFingers) fingers together…"
                }
                previousTime = timestamp
                return decision
            }
            if decision.elapsed > 0.1 {
                reject("Place both fingers together, then swipe.")
                return decision
            }
            assembledIDs = ids
            assembledAt = timestamp
            previousPositions = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        }
        let interval = timestamp - (previousTime ?? timestamp)
        if interval < 0 || interval > 0.18 {
            reject("Touch tracking was interrupted. Lift your fingers to reset.")
            return decision
        }
        if interval == 0 && decision.samples > 0 { return decision }
        previousTime = timestamp
        decision.samples += 1
        let horizontal = decision.region.isTop && configuration.topHorizontal
        var netAxis = 0.0, netPerpendicular = 0.0, delta = 0.0, path = 0.0
        var perFingerDisplacements: [Double] = []
        for contact in contacts {
            guard let start = firstPositions[contact.id], let previous = previousPositions[contact.id] else { continue }
            let dx = contact.x - previous.x, dy = contact.y - previous.y
            let step = hypot(dx, dy)
            if step > 0.18 {
                reject("Contact position jumped. Lift your fingers to reset.")
                return decision
            }
            pathLengths[contact.id, default: 0] += step
            path += pathLengths[contact.id, default: 0]
            let axis = horizontal ? contact.x - start.x : contact.y - start.y
            netAxis += axis
            netPerpendicular += horizontal ? contact.y - start.y : contact.x - start.x
            delta += horizontal ? dx : dy
            perFingerDisplacements.append(axis)
            previousPositions[contact.id] = contact
        }
        netAxis /= count
        netPerpendicular /= count
        path /= count
        decision.displacement = abs(netAxis)
        decision.straightness = path > 0.00001 ? min(1, abs(netAxis) / path) : 0
        if decision.phase == .accepted {
            decision.delta = delta / count
            return decision
        }
        let enoughTime = timestamp - (assembledAt ?? timestamp) >= configuration.minimumLifetime
        let enoughSamples = decision.samples >= configuration.minimumSamples
        guard enoughTime && enoughSamples else { return decision }
        if abs(netPerpendicular) > max(configuration.minimumDisplacement, abs(netAxis) * 1.2) {
            reject(horizontal ? "Swipe left or right along this top zone." : "Swipe up or down along this side zone.")
        } else if path > configuration.minimumDisplacement * 2.5 && decision.straightness < 0.45 {
            reject("Movement was mostly jitter or backtracking. Try a steady swipe.")
        } else if decision.displacement >= configuration.minimumDisplacement &&
                    decision.straightness >= configuration.requiredStraightness &&
                    perFingerDisplacements.allSatisfy({ abs($0) >= configuration.minimumDisplacement * 0.65 && $0 * netAxis > 0 }) {
            decision.phase = .accepted
            decision.reason = "Stable contacts, clear direction and enough movement confirmed."
            decision.justAccepted = true
            // Consume activation movement to avoid a jump on confirmation.
            decision.delta = 0
        } else if decision.elapsed > configuration.restingDeadline {
            reject("Contact stayed still or unclear too long. Lift, then swipe deliberately.")
        }
        return decision
    }
    private mutating func reject(_ reason: String) {
        decision.justRejected = decision.phase != .rejected
        decision.phase = .rejected
        decision.reason = reason
        decision.delta = 0
    }
}

/// Clamp each relative sample, so overshooting a bound never delays reversal.
struct RelativeGestureValue {
    private(set) var value: Double
    mutating func apply(delta: Double, sensitivity: Double, inverted: Bool, bounds: ClosedRange<Double>) -> Double {
        guard delta.isFinite, sensitivity.isFinite else { return value }
        value = min(bounds.upperBound, max(bounds.lowerBound,
                    value + delta * max(0.1, sensitivity) * 0.9 * (inverted ? -1 : 1)))
        return value
    }
}

/// Ownership belongs to an entire precise-scroll sequence, including inertia.
/// Mouse wheels and a new unrelated gesture never inherit old ownership.
struct GestureScrollCapture {
    private var captured = false
    private var momentumUntil = 0.0

    mutating func consume(precise: Bool, momentum: Bool, began: Bool, ended: Bool,
                          eligible: Bool, at time: Double) -> Bool {
        guard precise else { return false }
        if momentum {
            let result = captured || time < momentumUntil
            if ended { captured = false; momentumUntil = 0 }
            return result
        }
        if began { captured = false; momentumUntil = 0 }
        if ended {
            let result = captured
            if result { momentumUntil = time + 1 }
            captured = false
            return result
        }
        if eligible { captured = true }
        if captured { momentumUntil = time + 1 }
        return captured
    }
}

#if !SWAY_GESTURE_TESTS
import AppKit
import Combine

final class GestureTelemetry: ObservableObject {
    static let shared = GestureTelemetry()
    struct Snapshot {
        var decision = GestureDecision()
        var acceptedCount = 0
        var rejectedCount = 0
    }
    // A single coherent publication per rendered sample. Publishing each field
    // separately invalidated every observing view up to 13 times per sample.
    @Published private(set) var snapshot = Snapshot()
    var phase: String { snapshot.decision.phase.rawValue }
    var reason: String { snapshot.decision.reason }
    var fingerCount: Int { snapshot.decision.count }
    var x: Double { snapshot.decision.x }
    var y: Double { snapshot.decision.y }
    var displacement: Double { snapshot.decision.displacement }
    var straightness: Double { snapshot.decision.straightness }
    var elapsedMilliseconds: Int { Int(snapshot.decision.elapsed * 1000) }
    var sampleCount: Int { snapshot.decision.samples }
    var activeZone: String { snapshot.decision.region.rawValue }
    var acceptedCount: Int { snapshot.acceptedCount }
    var rejectedCount: Int { snapshot.rejectedCount }
    @Published var isTesting = false {
        didSet {
            if isTesting != oldValue {
                lastPublish = -Double.infinity
                TrackpadMonitor.shared.cancelCurrentGesture()
            }
        }
    }
    private var lastPublish = -Double.infinity

    func resetCounters() {
        snapshot = Snapshot()
        lastPublish = -Double.infinity
    }

    func monitorStopped() {
        guard isTesting else { return }
        var next = snapshot
        next.decision = GestureDecision(reason: "Enable Sway to detect gestures.")
        snapshot = next
    }

    func publish(_ decision: GestureDecision, at time: Double, force: Bool = false) {
        // No SwiftUI work, trail updates or counter churn during normal use.
        guard isTesting else { return }
        guard force || decision.justAccepted || decision.justRejected || decision.count == 0 ||
                time - lastPublish >= 1.0 / 30 else { return }
        lastPublish = time
        var next = snapshot
        next.decision = decision
        if decision.justAccepted { next.acceptedCount += 1 }
        if decision.justRejected { next.rejectedCount += 1 }
        snapshot = next
    }
}
#endif
