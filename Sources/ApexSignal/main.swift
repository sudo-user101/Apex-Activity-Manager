// apex-signal: ends, pauses or resumes processes for Apex as administrator.
//
//   apex-signal TERM|KILL|STOP|CONT pid@startMicros ...
//
// Apex runs it through the administrator prompt for processes that belong to
// another user or the system. It never takes a bare PID: each target is a
// process identity (PID + start time), checked here, independently of the
// app, and signalled through its audit token (`ProcessSignal.send`), so a
// PID that now belongs to another process is refused, never signalled.
// One line per target: "pid@start result". Exit status 0 when every target
// was signalled or had already exited, 1 otherwise, 2 for bad arguments.
import Darwin
import ProcessIdentityCore

let signals: [String: Int32] = ["TERM": SIGTERM, "KILL": SIGKILL, "STOP": SIGSTOP, "CONT": SIGCONT]
let args = Array(CommandLine.arguments.dropFirst())

guard let name = args.first, let sig = signals[name], args.count >= 2, args.count <= 513 else {
    print("usage: apex-signal TERM|KILL|STOP|CONT pid@startMicros ...")
    exit(2)
}

var allDone = true
for arg in args.dropFirst() {
    guard let target = ProcessIdentity(argument: arg) else {
        print("\(arg) invalid")
        allDone = false
        continue
    }
    // PID 1 (launchd) and this tool are refused inside `send`.
    let result = ProcessSignal.send(sig, to: target)
    print("\(target.argument) \(result.word)")
    if !result.isDone { allDone = false }
}
exit(allDone ? 0 : 1)
