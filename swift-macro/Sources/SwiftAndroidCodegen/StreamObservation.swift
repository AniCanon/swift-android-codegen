/// Pull-based access to an `AsyncSequence` for callers that cannot receive callbacks.
///
/// Serves a single consumer: overlapping `next()` calls are not supported.
public final class StreamObservation<Element: Sendable>: Sendable {
    private let relay: StreamObservationRelay<Element>
    private let pump: Task<Void, Never>

    public init<Source: AsyncSequence & Sendable>(_ source: Source) where Source.Element == Element {
        let relay = StreamObservationRelay<Element>()
        self.relay = relay
        self.pump = Task {
            do {
                for try await element in source {
                    await relay.push(element)
                }
                await relay.finish(.success(()))
            } catch {
                await relay.finish(.failure(error))
            }
        }
    }

    deinit {
        self.pump.cancel()
        let relay = self.relay
        Task { await relay.cancel() }
    }

    /// `nil` once the source has finished or the observation was cancelled.
    public func next() async throws -> Element? {
        try await self.relay.next()
    }

    /// Stops the source, drops undelivered elements and ends any waiting `next()` with `nil`.
    public func cancel() async {
        self.pump.cancel()
        await self.relay.cancel()
    }
}

private actor StreamObservationRelay<Element: Sendable> {
    private var buffer: [Element] = []
    /// `nil` while open. A failure is delivered once, then the relay reads as finished.
    private var ending: Result<Void, Error>?
    private var waiter: CheckedContinuation<Element?, Error>?

    func push(_ element: Element) {
        guard self.ending == nil else { return }
        if let waiter = self.waiter {
            self.waiter = nil
            waiter.resume(returning: element)
        } else {
            self.buffer.append(element)
        }
    }

    func finish(_ result: Result<Void, Error>) {
        guard self.ending == nil else { return }
        self.ending = result
        guard let waiter = self.waiter else { return }
        self.waiter = nil
        self.ending = .success(())
        switch result {
        case .success:
            waiter.resume(returning: nil)
        case let .failure(error):
            waiter.resume(throwing: error)
        }
    }

    func cancel() {
        self.buffer.removeAll()
        self.finish(.success(()))
    }

    func next() async throws -> Element? {
        if !self.buffer.isEmpty {
            return self.buffer.removeFirst()
        }
        if let ending = self.ending {
            self.ending = .success(())
            if case let .failure(error) = ending {
                throw error
            }
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.waiter = continuation
        }
    }
}
