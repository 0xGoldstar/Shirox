import JavaScriptCore
import XCTest
@testable import Shirox

/// What Seanime providers expect of their host, supplied by the bundled runtime.
@MainActor
final class SeanimeRuntimeTests: XCTestCase {
    private let html = """
    <div class="item"><a class="t" href="/a" title="A">Alpha</a><img src="/a.png"></div>
    <div class="item"><a class="t" href="/b">Beta</a><img src="/b.png"></div>
    """

    private func evaluate(_ script: String) -> JSValue {
        let context = SeanimeJSHarness.context()
        context.setObject(html, forKeyedSubscript: "html" as NSString)
        return context.evaluateScript(script)
    }

    /// Seanime's callbacks get selections, not nodes.
    func testLoadDocCallbacksGetSelections() {
        let value = evaluate("""
        const out = []; LoadDoc(html)("div.item").each((i, el) => {
          out.push(el.find("a.t").text().trim() + "|" + el.find("a.t").attrs()["href"] + "|" + el.find("img").attr("src"));
        }); JSON.stringify(out)
        """)
        XCTAssertEqual(value.toString(), #"["Alpha|/a|/a.png","Beta|/b|/b.png"]"#)
    }

    func testLoadDocMapFirstFilterAndLength() {
        XCTAssertEqual(evaluate(#"JSON.stringify(LoadDoc(html)("a.t").map((i, e) => e.attr("href")))"#).toString(),
                       #"["/a","/b"]"#)
        XCTAssertEqual(evaluate(#"LoadDoc(html)("a.t").first().text()"#).toString(), "Alpha")
        XCTAssertEqual(evaluate(#"LoadDoc(html)("div.item").length"#).toInt32(), 2)
        XCTAssertEqual(evaluate(#"LoadDoc(html)("a.t").filter((i, e) => e.attr("title") === "A").text()"#).toString(),
                       "Alpha")
    }

    func testStoreAndBase64() {
        XCTAssertEqual(evaluate(#"$store.set("k", 3); $store.has("k") && $store.get("k")"#).toInt32(), 3)
        XCTAssertEqual(evaluate(#"atob(btoa("hello"))"#).toString(), "hello")
        XCTAssertEqual(evaluate(#"Buffer.from("aGk=", "base64").toString("utf8")"#).toString(), "hi")
        XCTAssertEqual(evaluate(#"$toString($toBytes("hé"))"#).toString(), "hé")
    }

    func testTheInstallToolsRemoveTypeScript() {
        let url = Bundle.main.url(forResource: "SeanimeInstall", withExtension: "js")!
        let context = JSContext()!
        context.evaluateScript(try! String(contentsOf: url, encoding: .utf8))
        let js = context.evaluateScript("""
        __seanimeStripTypeScript("class Provider { api: string = 'x'; async search(opts: { query: string }): Promise<any[]> { return [this.api]; } }")
        """).toString()!
        XCTAssertFalse(js.contains(": string"))
        let run = JSContext()!
        XCTAssertEqual(run.evaluateScript(js + "; typeof Provider").toString(), "function")
    }
}
