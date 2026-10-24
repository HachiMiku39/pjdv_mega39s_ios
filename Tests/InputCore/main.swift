import Foundation
let input = InputStore()
// A four-face keyboard chord must release all four together, without releasing
// the individual face key or physical controller held across the space release.
input.update(source: "space", state: PadState(buttons: [.x, .y, .a, .b]))
input.update(source: "keyboard-d", state: PadState(buttons: .a))
assert(input.snapshot().pad.buttons.rawValue == 0xF)
input.remove(source: "space")
assert(input.snapshot().pad.buttons == .a)
input.remove(source: "keyboard-d")
assert(input.snapshot().pad.buttons.isEmpty)
input.update(source: "virtual", state: PadState(buttons: [.a, .b]))
input.update(source: "controller", state: PadState(buttons: [.a, .x]))
assert(input.snapshot().pad.buttons == [.a, .b, .x])
input.remove(source: "virtual")
assert(input.snapshot().pad.buttons == [.a, .x])
input.update(source: "axes", state: PadState(leftStick: SIMD2(2, Float.nan), rightStick: SIMD2(-3, 0.5)))
assert(input.snapshot().pad.leftStick == SIMD2(1, 0))
assert(input.snapshot().pad.rightStick == SIMD2(-1, 0.5))
for id in 0..<11 { input.touch(id: id, x: 2, y: -1) }
assert(input.snapshot().touches.count == 10)
assert(input.snapshot().touches.allSatisfy { $0.x == 1 && $0.y == 0 })
input.endTouch(id: 4)
input.touch(id: 11, x: 0.4, y: 0.6)
assert(input.snapshot().touches.count == 10)
let timestamp = input.snapshot().timestampNanoseconds
assert(input.snapshot().timestampNanoseconds >= timestamp)
DispatchQueue.concurrentPerform(iterations: 8) { worker in
    for _ in 0..<1000 {
        input.update(source: "worker-\(worker)", state: PadState(buttons: .zr))
        _ = input.snapshot()
        input.remove(source: "worker-\(worker)")
    }
}
assert(input.snapshot().pad.buttons == [.a, .x])
input.clear()
assert(input.snapshot().pad.buttons.isEmpty && input.snapshot().touches.isEmpty)
print("Input invariants passed: source isolation, axes, multitouch limit, cancellation, concurrency")

// Simulate a controller-thread callback completing after the main-thread lift.
let orderedInput = InputStore()
orderedInput.touch(id: 0, x: 0.2, y: 0.5)
let staleDown = orderedInput.snapshot()
orderedInput.endTouch(id: 0)
let released = orderedInput.snapshot()
var delivered: [InputFrame] = [], resets = 0
let sink = OrderedInputSink { frame, reset in delivered.append(frame); if reset { resets += 1 } }
sink.publish(released); sink.publish(staleDown); sink.publish(released)
assert(delivered.count == 1 && delivered.last!.touches.isEmpty)
orderedInput.touch(id: 0, x: 0.8, y: 0.5); sink.publish(orderedInput.snapshot())
orderedInput.clear(); sink.publish(orderedInput.snapshot())
assert(delivered.count == 3 && delivered.last!.touches.isEmpty && resets == 2)
print("Ordered native input publication passed: stale down rejection, duplicate rejection and cancellation generation")
