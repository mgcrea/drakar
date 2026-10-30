import Foundation

/// Runs a short-lived process to its end: both outputs read as they come, so a full pipe never
/// stalls it, and stopped after a timeout or when the caller is cancelled.
///
/// Nothing here blocks a thread of Swift's shared pool. The pipes are read on queues of their
/// own and the end is awaited through the termination handler. `waitUntilExit` and
/// `readDataToEndOfFile` in a detached task each held a pool thread instead: on CI's three
/// cores a few process tests at once took every thread, including the one the timeout needed,
/// and the 1.0.0 release run hung for three hours (`ClaudeVersionTests.asksTheBinary`, seen in
/// about 3 of 80 local runs since 2026-10-04 too).
public enum ProcessRunner {
  public struct Output: Sendable {
    public var status: Int32
    public var output: Data
    public var errors: Data
    /// Stopped by the timeout.
    public var timedOut: Bool
  }

  /// How long a stopped process has to end before it is killed.
  public static let grace = DispatchTimeInterval.seconds(2)

  /// A value given once, waited for by one caller whether or not its task is cancelled: the
  /// process's end and its outputs are waited for even after a cancel asked it to stop.
  private final class Latch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    func give(_ value: Value) {
      lock.lock()
      guard self.value == nil else { return lock.unlock() }
      self.value = value
      let waiter = waiter
      self.waiter = nil
      lock.unlock()
      waiter?.resume(returning: value)
    }

    func wait() async -> Value {
      await withCheckedContinuation { continuation in
        lock.lock()
        if let value {
          lock.unlock()
          continuation.resume(returning: value)
        } else {
          waiter = continuation
          lock.unlock()
        }
      }
    }
  }

  /// What one pipe says, read as it comes on a queue of its own, to its end or until `stop()`,
  /// which reads what the pipe still holds and closes the read end.
  private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let source: DispatchSourceRead
    private let result = Latch<Data>()
    /// Touched on the source's queue only.
    private var data = Data()

    init(_ pipe: Pipe) {
      handle = pipe.fileHandleForReading
      let descriptor = handle.fileDescriptor
      source = DispatchSource.makeReadSource(
        fileDescriptor: descriptor, queue: DispatchQueue(label: "drakar.process.pipe"))
      source.setEventHandler { [self] in
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
          data.append(contentsOf: buffer[..<count])
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
          source.cancel()
        }
      }
      // After the cancel handler no event handler runs, so the read end closes safely here,
      // once what is already in the pipe is read: a stop after the process ended loses none
      // of what it wrote. A megabyte at most, far more than a pipe holds: a job left behind
      // that keeps writing would otherwise keep this loop going.
      source.setCancelHandler { [self] in
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var drained = 0
        while drained < 1 << 20 {
          let count = Darwin.read(descriptor, &buffer, buffer.count)
          drained += max(count, 0)
          if count > 0 {
            data.append(contentsOf: buffer[..<count])
          } else if count < 0, errno == EINTR {
            continue
          } else {
            break
          }
        }
        try? handle.close()
        result.give(data)
      }
      source.resume()
    }

    func stop() { source.cancel() }

    func read() async -> Data { await result.wait() }
  }

  /// `environment` nil inherits this process's. `readsErrors` false sends standard error to
  /// /dev/null, and `errors` comes back empty. Throws only when the process cannot start.
  public static func run(
    _ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
    readsErrors: Bool = true, timeout: Duration
  ) async throws -> Output {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment { process.environment = environment }
    let output = Pipe()
    let errors = readsErrors ? Pipe() : nil
    process.standardOutput = output
    process.standardError = errors ?? FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let ended = Latch<Bool>()
    process.terminationHandler = { _ in ended.give(true) }
    try process.run()
    let out = PipeReader(output)
    let err = errors.map(PipeReader.init)
    // Asks the process to end; after the grace, ends it, and stops reading pipes in case its
    // end is never reported.
    let stop: @Sendable () -> Void = {
      process.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        out.stop()
        err?.stop()
      }
    }
    return await withTaskCancellationHandler {
      let watchdog = Task {
        try await Task.sleep(for: timeout)
        guard process.isRunning else { return false }
        stop()
        return true
      }
      // Once the process has ended, what it wrote is all in the pipes: the readers stop there
      // rather than wait for an end of file that a job it left behind (a shell's `cmd &`) can
      // hold off for as long as the job runs.
      _ = await ended.wait()
      out.stop()
      err?.stop()
      let outData = await out.read()
      let errData = await err?.read() ?? Data()
      watchdog.cancel()
      let timedOut = (try? await watchdog.value) == true
      return Output(
        status: process.terminationStatus, output: outData, errors: errData, timedOut: timedOut)
    } onCancel: {
      stop()
    }
  }
}
