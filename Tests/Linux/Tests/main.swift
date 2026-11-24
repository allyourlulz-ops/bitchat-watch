//
// Linux harness entry point. Each suite registers checks; failures are counted.
// SPDX-License-Identifier: GPL-3.0-or-later
//
import Foundation

var harnessFailures = 0
var harnessPasses = 0
let repoRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath

func check(_ cond: @autoclosure () throws -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    if (try? cond()) == true { harnessPasses += 1 } else {
        harnessFailures += 1
        print("FAIL: \(name) (\((file as NSString).lastPathComponent):\(line))")
    }
}

func hex(_ s: String) -> Data { return Data(hexString: s)! }

let suites: [(String, () throws -> Void)] = [
    ("crypto primitives (RFC vectors)", runCryptoVectorTests),
    ("bitchat wire protocol", runWireTests),
    ("upstream Noise vectors", runNoiseVectorTests),
    ("bitchat mesh engine (leaf)", runMeshEngineTests),
    ("tester core <-> shared interop", runTesterInteropTests),
    ("meshtastic codec", runMeshtasticTests),
    ("meshcore codec", runMeshCoreTests),
    ("channel chat protocol", runChannelTests),
    ("app core (store, budget, companion)", runAppCoreTests),
    ("mac tester shell logic", runTesterShellTests),
]

for (name, suite) in suites {
    let before = harnessFailures
    do { try suite() } catch {
        harnessFailures += 1
        print("FAIL: suite \(name) threw \(error)")
    }
    print("[\(harnessFailures == before ? "ok" : "FAILED")] \(name)")
}
print("passes=\(harnessPasses) failures=\(harnessFailures)")
exit(harnessFailures == 0 ? 0 : 1)
