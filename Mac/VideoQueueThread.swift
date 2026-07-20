import Darwin

/// Names the current GCD worker thread for Instruments / sample-based profilers.
/// `sender.video` is a queue label, not a thread name — pool threads otherwise
/// show up as anonymous "Thread N" rows.
enum VideoQueueThread {
    static func markSenderVideo() {
        pthread_setname_np("sender.video")
    }

    /// Stable per-thread id (matches `pthread_threadid_np` / sample context).
    static var id: UInt64 {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        return tid
    }
}
