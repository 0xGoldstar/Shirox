import JavaScriptCore
import XCTest

/// The bundled Seanime runtime in a bare `JSContext`, and a way to call its async functions.
/// The fakes used with it never wait on timers or the network, so their promises settle
/// before `evaluateScript` returns.
@MainActor
enum SeanimeJSHarness {
    struct Failure: Error, Equatable { let message: String }

    static var runtimeSource: String {
        let url = Bundle.main.url(forResource: "SeanimeRuntime", withExtension: "js")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    static func context(provider script: String = "", kind: String = "manga", dub: Bool = false,
                        host: String = "") -> JSContext {
        let context = JSContext()!
        // What the engine defines before the runtime — a stand-in `fetch`, say.
        context.evaluateScript(host)
        context.setObject(["kind": kind, "name": "Test", "dub": dub], forKeyedSubscript: "__seanime" as NSString)
        context.evaluateScript(runtimeSource)
        context.evaluateScript(script)
        return context
    }

    /// What a global function's promise resolves to — strings as they are, anything else as JSON.
    static func call(_ context: JSContext, _ function: String, _ arguments: [Any] = []) -> Result<String, Failure> {
        var outcome: Result<String, Failure> = .failure(Failure(message: "never settled"))
        let done: @convention(block) (String) -> Void = { outcome = .success($0) }
        let fail: @convention(block) (String) -> Void = { outcome = .failure(Failure(message: $0)) }
        context.setObject(done, forKeyedSubscript: "__testDone" as NSString)
        context.setObject(fail, forKeyedSubscript: "__testFail" as NSString)
        context.setObject(arguments, forKeyedSubscript: "__testArguments" as NSString)
        context.evaluateScript("""
        Promise.resolve().then(() => \(function).apply(null, __testArguments)).then(
          r => __testDone(typeof r === "string" ? r : JSON.stringify(r)),
          e => __testFail(String((e && e.message) || e)))
        """)
        return outcome
    }

    static func json(_ string: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(string.utf8), options: [.fragmentsAllowed])
    }
}
