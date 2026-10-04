import Darwin

/// What the kernel says about a process's parent. Ported, cut down, from Armada.
public enum ProcessAncestry {
  /// The parent pid, or nil if the process is gone. `sysctl` returns 0 and writes nothing
  /// for a pid that does not exist, so the size and pid are checked, not just the result.
  public static func parent(of pid: Int32) -> Int32? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0,
      info.kp_proc.p_pid == pid, info.kp_eproc.e_ppid > 0
    else { return nil }
    return info.kp_eproc.e_ppid
  }
}
