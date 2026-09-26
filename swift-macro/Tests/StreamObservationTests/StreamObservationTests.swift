import SwiftAndroidCodegen
import Testing

@Suite("StreamObservation")
struct StreamObservationTests {
    struct Boom: Error, Equatable {}

    @Test("Delivers every element, then nil")
    func deliversElementsThenNil() async throws {
        let observation = StreamObservation(AsyncStream<Int> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.finish()
        })

        #expect(try await observation.next() == 1)
        #expect(try await observation.next() == 2)
        #expect(try await observation.next() == nil)
        #expect(try await observation.next() == nil)
    }

    @Test("Rethrows the source error once, then returns nil")
    func rethrowsSourceError() async throws {
        let observation = StreamObservation(AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(1)
            continuation.finish(throwing: Boom())
        })

        #expect(try await observation.next() == 1)
        await #expect(throws: Boom.self) { try await observation.next() }
        #expect(try await observation.next() == nil)
    }

    @Test("Cancel ends a waiting next with nil")
    func cancelEndsWaitingNext() async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let observation = StreamObservation(stream)

        async let pending = observation.next()
        await observation.cancel()

        #expect(try await pending == nil)
        withExtendedLifetime(continuation) {}
    }

    @Test("Cancel terminates the source")
    func cancelTerminatesSource() async {
        let (terminated, terminatedContinuation) = AsyncStream<Void>.makeStream()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        continuation.onTermination = { _ in
            terminatedContinuation.yield()
            terminatedContinuation.finish()
        }
        let observation = StreamObservation(stream)

        await observation.cancel()

        var iterator = terminated.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test("Next after cancel returns nil even when the source keeps yielding")
    func nextAfterCancelReturnsNil() async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let observation = StreamObservation(stream)

        await observation.cancel()
        continuation.yield(7)

        #expect(try await observation.next() == nil)
    }

    /// Lets a test wait until a concurrently-running iterator has actually started, so
    /// cancellation lands while the source is live rather than before it ran at all.
    private actor SpinGate {
        private var started = false

        func markStarted() {
            self.started = true
        }

        func waitUntilStarted() async {
            while !self.started {
                await Task.yield()
            }
        }
    }

    /// A source whose iterator spins on `Task.isCancelled` and throws `CancellationError` the
    /// moment cancellation is observed, with no further suspension — reproduces sources built on
    /// `Task.checkCancellation()`, racing the source's own failure against `cancel()`'s resolution.
    private struct SpinningSequence: AsyncSequence, Sendable {
        let gate: SpinGate

        struct Iterator: AsyncIteratorProtocol {
            let gate: SpinGate

            func next() async throws -> Int? {
                await self.gate.markStarted()
                while !Task.isCancelled {
                    await Task.yield()
                }
                throw CancellationError()
            }
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(gate: self.gate)
        }
    }

    /// A source that fails on its first `next()` call, signalling `gate` right before throwing so a
    /// test can wait until the pump task has actually recorded the failure.
    private struct FailingSequence: AsyncSequence, Sendable {
        let gate: SpinGate

        struct Iterator: AsyncIteratorProtocol {
            let gate: SpinGate
            var thrown = false

            mutating func next() async throws -> Int? {
                guard !self.thrown else { return nil }
                self.thrown = true
                await self.gate.markStarted()
                throw Boom()
            }
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(gate: self.gate)
        }
    }

    @Test("Cancel after an undelivered source failure still resolves next with nil")
    func cancelAfterUndeliveredFailureReturnsNil() async throws {
        let gate = SpinGate()
        let observation = StreamObservation(FailingSequence(gate: gate))

        await gate.waitUntilStarted()
        for _ in 0..<50 { await Task.yield() }

        await observation.cancel()

        #expect(try await observation.next() == nil)
    }

    @Test("Cancel resolves a waiting next with nil even when the source throws CancellationError")
    func cancelResolvesWaitingNextDespiteSourceCancellationError() async throws {
        for _ in 0..<50 {
            let gate = SpinGate()
            let observation = StreamObservation(SpinningSequence(gate: gate))

            async let pending = observation.next()
            await gate.waitUntilStarted()
            await observation.cancel()

            #expect(try await pending == nil)
        }
    }
}
