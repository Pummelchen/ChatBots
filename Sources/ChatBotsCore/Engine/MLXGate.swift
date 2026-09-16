// ChatBotsCore — the serial gate a model call passes through
//
// Split out of `MLXEngine.swift`, which held the engine, its sampling settings, its text assembler and
// its supporting actors in one 942-line file. The types did not change.

import Foundation

/// Serialises every Metal-touching operation in the process.
///
/// Two MLX model instances are loaded here, and MLX's Metal backend is not safe to
/// drive from two places at once: running a second evaluation while another is in flight
/// aborts inside `mlx::core::metal::Device::get_command_encoder` /
/// `fast::CustomKernel::eval_gpu` with `EXC_BAD_ACCESS`, which showed up as
/// `Segmentation fault: 11` crash reports. Weight loading is serialised for the same
/// reason — two concurrent loads each build command encoders and compile kernels.
///
/// This costs almost nothing in practice: a conversation turn needs the previous
/// speaker's text to exist, so the turn loop is sequential anyway, and the GPU
/// serialises concurrent work rather than overlapping it (measured: each seat at exactly
/// 50% of its solo rate). It also makes the `--benchmark` mode honest.
actor MLXGate {
    static let shared = MLXGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Hand the slot straight to the next waiter; `busy` stays true.
            waiters.removeFirst().resume()
        }
    }

    /// Run `body` with exclusive access to MLX.
    ///
    /// `rethrows` with an explicit release rather than `defer { Task { ... } }`: a
    /// detached release task could let a waiter in before `body` has actually finished
    /// with the GPU, which is the exact race this gate exists to prevent.
    static func exclusive<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await shared.acquire()
        do {
            let result = try await body()
            await shared.release()
            return result
        } catch {
            await shared.release()
            throw error
        }
    }
}

/// Progress callbacks arrive from download threads; throttle before touching UI state.
///
/// `@unchecked Sendable` because its one piece of mutable state, `lastReported`, is confined to
/// `lock`: `report` is the only method that touches it and holds `lock` across the whole
/// read-modify-write. The `handler` call is deliberately made after `lock.unlock()`, so an
/// arbitrary callback never runs while the box is locked. What keeps the confinement true is
/// that `lastReported` is private, `lock` is a `let`, and `report` is the only accessor.
