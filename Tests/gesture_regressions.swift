import Foundation

@main
enum GestureRegressionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(label)") }
    }
    static func touch(_ id: Int32 = 1, _ x: Double = 0.1, _ y: Double = 0.4) -> GestureContact {
        GestureContact(id: id, x: x, y: y)
    }
    static func feed(_ engine: inout EdgeGestureRecognizer, _ config: GestureConfiguration,
                     _ time: Double, _ contacts: [GestureContact]) -> GestureDecision {
        engine.process(contacts: contacts, timestamp: time, configuration: config)
    }
    static func accepted(_ config: GestureConfiguration, start: Double = 1) -> EdgeGestureRecognizer {
        var engine = EdgeGestureRecognizer()
        for index in 0...12 {
            let y = 0.4 + Double(index) * 0.004
            let contacts = config.requiredFingers == 1 ? [touch(1, 0.1, y)] : [touch(1, 0.1, y), touch(2, 0.15, y)]
            _ = feed(&engine, config, start + Double(index) * 0.01, contacts)
        }
        expect(engine.decision.phase == .accepted, "deliberate swipe accepts")
        return engine
    }
    static func main() {
        var one = GestureConfiguration()
        one.requiredFingers = 1
        var engine = EdgeGestureRecognizer()

        _ = feed(&engine, one, 1, [touch(1, 0.5, 0.4)])
        for i in 1...15 { _ = feed(&engine, one, 1 + Double(i) * 0.01, [touch(1, 0.1, 0.4 + Double(i) * 0.01)]) }
        expect(engine.decision.phase == .rejected, "center-to-edge cannot activate")
        expect(engine.decision.region == .none, "zone locked at real touchdown")

        engine = EdgeGestureRecognizer()
        _ = feed(&engine, one, 1, [touch()])
        let early = feed(&engine, one, 1.02, [touch(1, 0.1, 0.5)])
        expect(early.phase == .gathering && early.delta == 0, "fast contact cannot bypass minimum lifetime")
        expect(feed(&engine, one, 1.03, []).phase == .rejected, "micro-contact rejected on lift")

        engine = EdgeGestureRecognizer()
        for i in 0...12 { _ = feed(&engine, one, 1 + Double(i) * 0.01, [touch(1, 0.1 + Double(i) * 0.003, 0.4)]) }
        expect(engine.decision.phase == .rejected, "sideways side-zone gesture rejected")
        var top = one
        top.topEnabled = true
        engine = EdgeGestureRecognizer()
        for i in 0...12 { _ = feed(&engine, top, 1 + Double(i) * 0.01, [touch(1, 0.3 + Double(i) * 0.004, 0.92)]) }
        expect(engine.decision.phase == .accepted && engine.decision.region == .topLeft, "horizontal top gesture uses x-axis evidence")
        top.topHorizontal = false
        engine = EdgeGestureRecognizer()
        for i in 0...12 { _ = feed(&engine, top, 1 + Double(i) * 0.01, [touch(1, 0.3, 0.9 + Double(i) * 0.004)]) }
        expect(engine.decision.phase == .accepted && engine.decision.region == .top, "vertical top gesture uses y-axis evidence")

        engine = accepted(one)
        let cancelled = engine.keyDown(at: 1.5)
        expect(cancelled.phase == .rejected, "typing cancels even an old accepted gesture")
        expect(feed(&engine, one, 2, [touch(1, 0.1, 0.55)]).phase == .rejected, "typing rejection persists after cooldown until lift")
        _ = feed(&engine, one, 2.01, [])
        _ = engine.keyDown(at: 2.1)
        expect(feed(&engine, one, 2.3, [touch()]).phase == .rejected, "fresh touch during typing cooldown blocked")

        engine = accepted(one)
        expect(feed(&engine, one, 1.13, [touch(9, 0.1, 0.452)]).phase == .rejected, "identity replacement with equal count blocked")
        engine = accepted(one)
        _ = feed(&engine, one, 1.13, [touch(1, 0.1, 0.45), touch(2, 0.12, 0.45)])
        expect(feed(&engine, one, 1.14, [touch(1, 0.1, 0.46)]).phase == .rejected, "extra contact locks out until full lift")

        let two = GestureConfiguration()
        engine = accepted(two)
        expect(feed(&engine, two, 1.13, [touch(2, 0.15, 0.452), touch(1, 0.1, 0.452)]).phase == .accepted,
               "contact-array reorder preserves identity")
        let partialLift = feed(&engine, two, 1.14, [touch(1, 0.1, 0.456)])
        expect(partialLift.ended && partialLift.delta == 0 && !engine.isCapturing,
               "first finger lifting immediately ends two-finger control")
        expect(partialLift.phase == .accepted, "normal staggered lift preserves a successful verdict")
        expect(feed(&engine, two, 1.15, [touch(1, 0.1, 0.5)]).delta == 0, "remaining finger cannot continue after partial lift")
        engine = EdgeGestureRecognizer()
        _ = feed(&engine, two, 1, [touch()])
        for i in 1...12 { _ = feed(&engine, two, 1 + Double(i) * 0.01,
                                  [touch(1, 0.1, 0.4 + Double(i) * 0.004), touch(2, 0.15, 0.4 + Double(i) * 0.004)]) }
        expect(engine.decision.phase == .accepted, "slightly staggered two-finger landing accepts")
        engine = EdgeGestureRecognizer()
        _ = feed(&engine, two, 1, [touch()])
        expect(feed(&engine, two, 1.15, [touch(), touch(2, 0.15, 0.4)]).phase == .rejected, "late second finger cannot join")
        engine = EdgeGestureRecognizer()
        expect(feed(&engine, two, 1, [touch(), touch(2, 0.6, 0.4)]).phase == .rejected, "two contacts must start same zone")
        engine = EdgeGestureRecognizer()
        for i in 0...12 { _ = feed(&engine, two, 1 + Double(i) * 0.01,
                                  [touch(1, 0.1, 0.4 + Double(i) * 0.004), touch(2, 0.15, 0.4)]) }
        expect(engine.decision.phase != .accepted, "moving finger plus resting palm cannot pass as coherent two-finger swipe")

        engine = EdgeGestureRecognizer()
        for i in 0...16 { _ = feed(&engine, one, 1 + Double(i) * 0.01,
                                  [touch(1, 0.1, i % 2 == 0 ? 0.4 : 0.405)]) }
        expect(engine.decision.phase == .rejected, "accumulated jitter is not directional displacement")
        engine = EdgeGestureRecognizer()
        for i in 0...50 { _ = feed(&engine, one, 1 + Double(i) * 0.01, [touch()]) }
        expect(engine.decision.phase == .rejected, "resting contact is rejected")
        expect(feed(&engine, one, 1.51, [touch(1, 0.1, 0.5)]).phase == .rejected, "resting contact cannot rearm without lifting")
        _ = feed(&engine, one, 1.52, [])
        expect(feed(&engine, one, 1.53, [touch(2)]).phase == .gathering, "fresh contact after lift does not inherit palm lockout")

        engine = accepted(one)
        expect(feed(&engine, one, 1.5, [touch(1, 0.1, 0.5)]).phase == .rejected, "tracking gap cannot make a jump")
        engine = EdgeGestureRecognizer()
        expect(feed(&engine, one, 1, [touch(1, .nan, 0.4)]).phase == .rejected, "NaN coordinates fail closed")
        engine = EdgeGestureRecognizer()
        expect(feed(&engine, two, 1, [touch(), touch()]).phase == .rejected, "duplicate contact identity rejected")
        engine = accepted(one)
        var changed = one
        changed.leftWidth = 0.3
        expect(feed(&engine, changed, 1.13, [touch(1, 0.1, 0.46)]).phase == .rejected, "settings change cancels in-flight gesture")
        var strict = one
        strict.strict = true
        _ = accepted(strict)

        // Geometry remains exact below 5%. Narrow zones do not weaken the
        // identity, timing or movement evidence needed to accept a swipe.
        for width in [0.01, 0.025] {
            var narrow = GestureConfiguration()
            narrow.leftWidth = width
            narrow.rightWidth = width
            expect(narrow.region(x: width, y: 0.4) == .left, "left boundary includes exact narrow width")
            expect(narrow.region(x: width + 0.0001, y: 0.4) == .none, "left narrow boundary has no hidden 5% hit area")
            expect(narrow.region(x: 1 - width, y: 0.4) == .right, "right boundary includes exact narrow width")
            expect(narrow.region(x: 1 - width - 0.0001, y: 0.4) == .none, "right narrow boundary has no hidden 5% hit area")
            expect(narrow.region(x: 0.5, y: 0.4) == .none, "narrow edges preserve ordinary center scrolling")
            for side in [GestureRegion.left, .right] {
                let x = side == .left ? width / 2 : 1 - width / 2
                for fingers in [1, 2] {
                    narrow.requiredFingers = fingers
                    engine = EdgeGestureRecognizer()
                    for index in 0...12 {
                        let y = 0.4 + Double(index) * 0.004
                        let contacts = fingers == 1 ? [touch(1, x, y)] : [touch(1, x, y), touch(2, x, y + 0.08)]
                        _ = feed(&engine, narrow, 1 + Double(index) * 0.01, contacts)
                    }
                    expect(engine.decision.phase == .accepted && engine.decision.region == side,
                           "\(width * 100)% \(side.rawValue) edge accepts a deliberate \(fingers)-finger swipe")
                    expect(engine.decision.samples >= narrow.minimumSamples && engine.decision.elapsed >= narrow.minimumLifetime,
                           "narrow zones retain full activation evidence")
                }
                narrow.requiredFingers = 1
                engine = EdgeGestureRecognizer()
                _ = feed(&engine, narrow, 1, [touch(1, 0.5, 0.4)])
                expect(feed(&engine, narrow, 1.01, [touch(1, x, 0.41)]).phase == .rejected,
                       "center contact cannot enter a narrow \(side.rawValue) edge and activate")
                var disabled = narrow
                disabled.enabledRegions.remove(side)
                engine = EdgeGestureRecognizer()
                expect(feed(&engine, disabled, 1, [touch(1, x, 0.4)]).phase == .rejected,
                       "disabled narrow \(side.rawValue) edge never captures a contact")
            }
            narrow.requiredFingers = 1
            narrow.topEnabled = true
            narrow.topHeight = width
            expect(narrow.region(x: 0.5, y: 1 - width - 0.0001) == .none, "top narrow boundary preserves center space")
            engine = EdgeGestureRecognizer()
            for index in 0...12 {
                _ = feed(&engine, narrow, 1 + Double(index) * 0.01,
                         [touch(1, 0.3 + Double(index) * 0.004, 1 - width / 2)])
            }
            expect(engine.decision.phase == .accepted && engine.decision.region == .topLeft,
                   "\(width * 100)% top strip accepts deliberate horizontal movement")
        }

        var level = RelativeGestureValue(value: 0.9)
        _ = level.apply(delta: 0.8, sensitivity: 1, inverted: false, bounds: 0...1)
        expect(level.value == 1, "value clamps at upper limit")
        let reversed = level.apply(delta: -0.01, sensitivity: 1, inverted: false, bounds: 0...1)
        expect(reversed < 1 && reversed > 0.98, "reverse responds immediately after overshoot")
        _ = level.apply(delta: .nan, sensitivity: 1, inverted: false, bounds: 0...1)
        expect(level.value == reversed, "invalid delta cannot corrupt control level")

        var scroll = GestureScrollCapture()
        expect(!scroll.consume(precise: false, phase: .began, eligible: true, at: 1), "mouse wheel never captured")
        expect(!scroll.consume(precise: true, phase: .mayBegin, eligible: true, at: 1.9), "preflight is not a movement event")
        expect(scroll.consume(precise: true, phase: .began, eligible: true, at: 2), "edge scroll acquired at begin")
        expect(scroll.consume(precise: true, phase: .changed, eligible: false, at: 2.1), "a captured stream does not leak movement after rejection")
        scroll.touchesEnded()
        expect(scroll.consume(precise: true, phase: .ended, eligible: false, at: 2.2), "captured lift consumed after native contacts end")
        expect(scroll.consume(precise: true, phase: .none, momentum: .began, eligible: false, at: 2.25), "captured momentum consumed after lift")
        expect(scroll.consume(precise: true, phase: .none, momentum: .changed, eligible: false, at: 3.5), "inertia does not leak after the old one-second timeout")
        expect(scroll.consume(precise: true, phase: .none, momentum: .changed, eligible: false, at: 5), "long captured inertia remains owned")
        expect(scroll.consume(precise: true, phase: .none, momentum: .ended, eligible: false, at: 5.1), "captured momentum end consumed")
        expect(!scroll.consume(precise: true, phase: .none, momentum: .changed, eligible: true, at: 5.2), "orphan inertia cannot acquire ownership from an edge touch")

        _ = scroll.consume(precise: true, phase: .began, eligible: true, at: 6)
        expect(!scroll.consume(precise: true, phase: .began, eligible: false, at: 6.1), "fresh ordinary scroll releases old ownership")
        expect(!scroll.consume(precise: true, phase: .changed, eligible: true, at: 6.2),
               "an ordinary scroll cannot be stolen when touch evidence arrives later")
        expect(scroll.blocksEdgeGesture, "normal scrolling also blocks a late hardware adjustment")
        expect(!scroll.consume(precise: true, phase: .ended, eligible: true, at: 6.3), "ordinary scroll end reaches its app")
        expect(!scroll.blocksEdgeGesture, "ordinary scroll end releases the touch lock")
        expect(!scroll.consume(precise: true, phase: .none, momentum: .began, eligible: true, at: 6.4), "ordinary inertia stays ordinary even over an edge")
        expect(!scroll.consume(precise: true, phase: .none, momentum: .ended, eligible: true, at: 7), "ordinary inertia end reaches its app")

        _ = scroll.consume(precise: true, phase: .began, eligible: true, at: 8)
        _ = scroll.consume(precise: true, phase: .ended, eligible: false, at: 8.1)
        expect(!scroll.consume(precise: true, phase: .mayBegin, eligible: false, at: 8.2), "new mayBegin clears old ownership immediately")
        expect(!scroll.consume(precise: true, phase: .changed, eligible: true, at: 8.3), "missing began favors normal scrolling, not stale capture")
        expect(!scroll.consume(precise: true, phase: .stationary, eligible: true, at: 8.4), "stationary event cannot steal an ordinary sequence")
        expect(!scroll.consume(precise: true, phase: .cancelled, eligible: true, at: 8.5), "ordinary cancellation reaches its app")

        expect(scroll.consume(precise: true, phase: .began, eligible: true, at: 9), "new edge swipe can capture after ordinary scrolling")
        expect(scroll.consume(precise: true, phase: .cancelled, eligible: false, at: 9.1), "captured cancellation is consumed")
        expect(!scroll.consume(precise: true, phase: .none, momentum: .began, eligible: true, at: 9.2), "cancelled gesture cannot claim inertia")
        _ = scroll.consume(precise: true, phase: .began, eligible: true, at: 10)
        _ = scroll.consume(precise: true, phase: .ended, eligible: false, at: 10.1)
        _ = scroll.consume(precise: true, phase: .cancelled, eligible: false, at: 10.2)
        expect(!scroll.consume(precise: true, phase: .none, momentum: .began, eligible: false, at: 10.3), "late cancellation clears a pending inertia handoff")

        _ = scroll.consume(precise: true, phase: .began, eligible: true, at: 11)
        _ = scroll.consume(precise: true, phase: .ended, eligible: false, at: 11.1)
        expect(!scroll.consume(precise: true, phase: .none, momentum: .began, eligible: true, at: 13), "unrelated delayed inertia cannot inherit old ownership")
        _ = scroll.consume(precise: true, phase: .began, eligible: true, at: 14)
        _ = scroll.consume(precise: true, phase: .ended, eligible: false, at: 14.1)
        _ = scroll.consume(precise: true, phase: .none, momentum: .began, eligible: false, at: 14.2)
        expect(!scroll.consume(precise: true, phase: .none, momentum: .began, eligible: true, at: 14.3), "new inertia begin never inherits an earlier inertia stream")

        _ = scroll.consume(precise: true, phase: .began, eligible: true, at: 15)
        expect(!scroll.consume(precise: true, phase: .none, eligible: true, at: 15.1), "phase-less precise wheel always passes through")
        expect(!scroll.consume(precise: false, phase: .began, eligible: true, at: 15.2), "interleaved mouse wheel passes through")
        expect(scroll.consume(precise: true, phase: .changed, eligible: false, at: 15.3), "mouse wheel does not reset trackpad ownership")
        expect(!scroll.consume(precise: true, phase: .none, momentum: .ended, eligible: false, at: 15.4), "late old inertia terminal cannot capture the fresh direct sequence")
        expect(scroll.consume(precise: true, phase: .changed, eligible: false, at: 15.5), "late old inertia terminal does not clear fresh ownership")
        expect(scroll.consume(precise: true, phase: .ended, momentum: .began, eligible: false, at: 15.6), "combined lift and inertia begin retains ownership")
        expect(scroll.consume(precise: true, phase: .none, momentum: .cancelled, eligible: false, at: 15.7), "inertia cancellation is consumed and clears ownership")
        expect(!scroll.consume(precise: true, phase: .none, momentum: .changed, eligible: false, at: 15.8), "cancelled inertia cannot suppress later events")

        _ = scroll.consume(precise: true, phase: .began, eligible: false, at: 16)
        expect(scroll.blocksEdgeGesture, "system scroll keeps contacts out of edge controls")
        scroll.touchesEnded()
        expect(!scroll.blocksEdgeGesture, "native lift releases old contact lock before delayed scroll end")
        scroll.prepare(phase: .began, momentum: .none)
        expect(!scroll.blocksEdgeGesture, "prepare clears previous ownership before draining fresh touches")
        expect(scroll.consume(precise: true, phase: .began, eligible: true, at: 16.1), "fresh edge works after normal scrolling")
        scroll = GestureScrollCapture() // event-tap interruption / monitor restart
        expect(!scroll.consume(precise: true, phase: .changed, eligible: true, at: 16.2), "restart never consumes half of an already-started stream")

        // Exercise delayed native evidence with the real recognizer: an already
        // delivered normal scroll may not begin changing volume on later frames.
        engine = EdgeGestureRecognizer()
        for index in 0...12 {
            let y = 0.4 + Double(index) * 0.004
            _ = feed(&engine, two, 17 + Double(index) * 0.01, [touch(1, 0.1, y), touch(2, 0.15, y)])
            if scroll.blocksEdgeGesture && engine.isCapturing {
                _ = engine.cancel(reason: "Normal scrolling started first.")
            }
            expect(engine.decision.phase == .rejected && engine.decision.delta == 0,
                   "late two-finger evidence cannot adjust hardware during ordinary scrolling")
        }
        _ = feed(&engine, two, 17.2, [])
        scroll.touchesEnded()
        scroll.prepare(phase: .began, momentum: .none)
        expect(feed(&engine, two, 17.3, [touch(), touch(2, 0.15, 0.4)]).phase == .gathering,
               "new contacts may gather edge intent after the ordinary scroll lifts")

        // Match the event tap's ordering: a queued lift and fresh touchdown
        // must be drained before choosing the owner, never after the first delta.
        let transitionInbox = GestureFrameInbox()
        scroll = GestureScrollCapture()
        engine = accepted(two, start: 20)
        _ = transitionInbox.enqueue(GestureInputFrame(contacts: [], timestamp: 20.13, generation: 1))
        _ = transitionInbox.enqueue(GestureInputFrame(contacts: [touch(3, 0.5), touch(4, 0.55)], timestamp: 20.14, generation: 1))
        scroll.prepare(phase: .began, momentum: .none)
        for frame in transitionInbox.takeBatch() {
            if frame.contacts.isEmpty { scroll.touchesEnded() }
            _ = feed(&engine, two, frame.timestamp, frame.contacts)
        }
        expect(!scroll.consume(precise: true, phase: .began,
                               eligible: engine.isCapturing && engine.decision.count == 2, at: 20.15),
               "queued center touchdown must not inherit the previous edge's capture")
        _ = transitionInbox.enqueue(GestureInputFrame(contacts: [], timestamp: 20.2, generation: 1))
        _ = transitionInbox.enqueue(GestureInputFrame(contacts: [touch(5, 0.1), touch(6, 0.15)], timestamp: 20.21, generation: 1))
        scroll.prepare(phase: .began, momentum: .none)
        for frame in transitionInbox.takeBatch() {
            if frame.contacts.isEmpty { scroll.touchesEnded() }
            _ = feed(&engine, two, frame.timestamp, frame.contacts)
            expect(!scroll.blocksEdgeGesture, "old ordinary stream must not reject queued fresh edge contacts")
        }
        expect(scroll.consume(precise: true, phase: .began,
                              eligible: engine.isCapturing && engine.decision.count == 2, at: 20.22),
               "queued edge touchdown can acquire a genuinely new scroll")
        for index in 1...12 {
            let y = 0.4 + Double(index) * 0.004
            _ = feed(&engine, two, 20.21 + Double(index) * 0.01, [touch(5, 0.1, y), touch(6, 0.15, y)])
            expect(scroll.consume(precise: true, phase: .changed, eligible: engine.isCapturing,
                                  at: 20.22 + Double(index) * 0.01), "fresh two-finger edge movement remains captured")
        }
        expect(engine.decision.phase == .accepted && engine.decision.delta > 0,
               "scroll ownership still allows deliberate two-finger control to activate and adjust")

        // Batching must reduce scheduled main-queue work, never erase the
        // temporary contact or identity changes needed for palm rejection.
        let inbox = GestureFrameInbox(capacity: 8)
        let first = GestureInputFrame(contacts: [touch()], timestamp: 1, generation: 1)
        expect(inbox.enqueue(first), "first input schedules one delivery")
        expect(!inbox.enqueue(GestureInputFrame(contacts: [touch(), touch(2)], timestamp: 1.01, generation: 1)),
               "queued extra contact reuses pending delivery")
        expect(!inbox.enqueue(GestureInputFrame(contacts: [touch()], timestamp: 1.02, generation: 1)),
               "queued contact removal reuses pending delivery")
        let preserved = inbox.takeBatch()
        expect(preserved.map { $0.contacts.count } == [1, 2, 1], "batch preserves a transient extra contact")
        engine = accepted(one)
        for (index, frame) in preserved.enumerated() {
            _ = feed(&engine, one, 1.13 + Double(index) * 0.01, frame.contacts)
        }
        expect(engine.decision.phase == .rejected, "batching cannot hide extra-contact rejection")
        expect(inbox.takeBatch().isEmpty, "draining a batch leaves no queued work")
        expect(inbox.enqueue(GestureInputFrame(contacts: [], timestamp: 2, generation: 1)),
               "new physical lift schedules a new delivery")
        expect(inbox.takeBatch().first?.contacts.isEmpty == true, "physical lift remains observable")

        let tinyInbox = GestureFrameInbox(capacity: 2)
        _ = tinyInbox.enqueue(first)
        _ = tinyInbox.enqueue(GestureInputFrame(contacts: [touch(2)], timestamp: 1.01, generation: 1))
        _ = tinyInbox.enqueue(GestureInputFrame(contacts: [touch()], timestamp: 1.02, generation: 1))
        let overflow = tinyInbox.takeBatch()
        expect(overflow.count == 1 && overflow[0].contacts.first?.x.isNaN == true,
               "overflow emits an explicit invalid sample rather than an invented lift")
        engine = EdgeGestureRecognizer()
        for frame in overflow { _ = feed(&engine, one, frame.timestamp, frame.contacts) }
        expect(engine.decision.phase == .rejected, "queue overflow fails closed")
        expect(!tinyInbox.enqueue(GestureInputFrame(contacts: [touch()], timestamp: 1.03, generation: 1)),
               "overflowed input cannot schedule touch-only continuation")
        expect(tinyInbox.takeBatch().isEmpty, "overflow latch prevents growing the queue while waiting for lift")
        expect(tinyInbox.enqueue(GestureInputFrame(contacts: [], timestamp: 1.04, generation: 1)),
               "real full lift releases overflow latch")
        _ = tinyInbox.enqueue(GestureInputFrame(contacts: [touch(3)], timestamp: 1.05, generation: 1))
        let recovery = tinyInbox.takeBatch()
        expect(recovery.count == 2 && recovery[0].contacts.isEmpty && recovery[1].contacts.first?.id == 3,
               "recovery keeps lift and new touchdown in order")
        for frame in recovery { _ = feed(&engine, one, frame.timestamp, frame.contacts) }
        expect(engine.decision.phase == .gathering, "only post-lift contact may gather evidence after overflow")

        _ = tinyInbox.enqueue(first)
        _ = tinyInbox.enqueue(GestureInputFrame(contacts: [touch(7)], timestamp: 5, generation: 2))
        let restarted = tinyInbox.takeBatch()
        expect(restarted.count == 1 && restarted[0].generation == 2,
               "new monitor generation drops stale queued input")
        tinyInbox.clear()
        expect(tinyInbox.takeBatch().isEmpty, "stopping removes queued input")
        expect(tinyInbox.enqueue(first), "cleared inbox can schedule a fresh monitor delivery")

        engine = accepted(two)
        _ = feed(&engine, two, 1.13, [touch(1, 0.1, 0.45), touch(2, 0.15, 0.45), touch(3)])
        for index in 0..<1000 {
            _ = feed(&engine, two, 1.14 + Double(index) * 0.01, [touch(8), touch(9)])
        }
        expect(engine.decision.phase == .rejected && !engine.isCapturing,
               "low-cost rejected-contact path stays locked through arbitrary identity replacement")
        _ = feed(&engine, two, 12, [])
        expect(feed(&engine, two, 12.01, [touch(), touch(2)]).phase == .gathering,
               "fast rejected path still resets only at full lift")
        print("PASS: \(checks) gesture regression checks")
    }
}
