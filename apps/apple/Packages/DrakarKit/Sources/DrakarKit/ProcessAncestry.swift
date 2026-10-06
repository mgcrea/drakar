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

extension ProcessAncestry {
  /// The TCP ports `pid` listens on, from its open sockets; none when it is gone or not
  /// ours to read.
  public static func listeningPorts(of pid: Int32) -> [Int] {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
    guard filled > 0 else { return [] }
    return descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
      .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
      .compactMap { descriptor in
        var info = socket_fdinfo()
        let expected = Int32(MemoryLayout<socket_fdinfo>.stride)
        guard
          proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, expected)
            == expected,
          info.psi.soi_kind == Int32(SOCKINFO_TCP),
          info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
        else { return nil }
        let port = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
        return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: port)))
      }
  }
}
