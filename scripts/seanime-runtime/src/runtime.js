// The Seanime runtime for Shirox: what Seanime providers expect of their host, on
// JavaScriptCore. The app evaluates it before a provider's script, with `__seanime` set to
// { kind: "manga" | "anime", name, dub }.
import "./prelude.js";
import { load } from "cheerio/slim";
import { Buffer } from "buffer";

// ---- LoadDoc: Seanime's goquery-style HTML API, over Cheerio ----
// Seanime hands callbacks a selection (`el.find(…)`), where Cheerio hands a node, and has
// `.attrs()` for every attribute of the first element.
class DocSelection {
  constructor($, selection) {
    this.$ = $;
    this.selection = selection;
    this.length = selection.length;
  }
  wrap(selection) { return new DocSelection(this.$, selection); }
  find(query) { return this.wrap(this.selection.find(query)); }
  children(query) { return this.wrap(query ? this.selection.children(query) : this.selection.children()); }
  parent(query) { return this.wrap(query ? this.selection.parent(query) : this.selection.parent()); }
  closest(query) { return this.wrap(this.selection.closest(query)); }
  next(query) { return this.wrap(query ? this.selection.next(query) : this.selection.next()); }
  prev(query) { return this.wrap(query ? this.selection.prev(query) : this.selection.prev()); }
  siblings(query) { return this.wrap(query ? this.selection.siblings(query) : this.selection.siblings()); }
  first() { return this.wrap(this.selection.first()); }
  last() { return this.wrap(this.selection.last()); }
  eq(index) { return this.wrap(this.selection.eq(index)); }
  filter(query) {
    return this.wrap(typeof query === "function"
      ? this.selection.filter((i, node) => query(i, this.wrap(this.$(node))))
      : this.selection.filter(query));
  }
  not(query) { return this.wrap(this.selection.not(query)); }
  is(query) { return this.selection.is(query); }
  hasClass(name) { return this.selection.hasClass(name); }
  text() { return this.selection.text(); }
  html() { return this.selection.html() ?? ""; }
  attr(name) { return this.selection.attr(name); }
  attrs() { return this.selection.attr() ?? {}; }
  data(name) { return this.selection.data(name); }
  each(callback) {
    this.selection.each((i, node) => { callback(i, this.wrap(this.$(node))); });
    return this;
  }
  map(callback) {
    const out = [];
    this.selection.each((i, node) => { out.push(callback(i, this.wrap(this.$(node)))); });
    return out;
  }
}

// ---- Helpers Seanime providers use ----
const store = new Map();
Object.assign(globalThis, {
  LoadDoc(html) {
    const $ = load(html ?? "");
    const doc = (query) => new DocSelection($, $(query));
    doc.find = doc;
    return doc;
  },
  Buffer,
  $store: {
    get: (key) => store.get(key),
    set: (key, value) => { store.set(key, value); },
    has: (key) => store.has(key),
    delete: (key) => store.delete(key),
  },
  $sleep: (ms) => new Promise((resolve) => (typeof setTimeout === "function" ? setTimeout(resolve, ms) : resolve())),
  $getUserPreference: () => undefined,
  $toString: (value) => (typeof value === "string" ? value : Buffer.from(value).toString("utf8")),
  $toBytes: (value) => Array.from(Buffer.from(String(value), "utf8")),
});
// Set by the app when it loads the module.
const host = () => globalThis.__seanime || { kind: "manga", name: "Seanime", dub: false };

// A provider's logs carry its name.
function describe(value) {
  if (typeof value === "string") return value;
  try { return JSON.stringify(value); } catch { return String(value); }
}
if (globalThis.console) {
  for (const level of ["log", "info", "warn", "error"]) {
    const original = globalThis.console[level];
    if (typeof original === "function") {
      globalThis.console[level] = (...args) =>
        original.call(globalThis.console, `[${host().name}] ` + args.map(describe).join(" "));
    }
  }
}
