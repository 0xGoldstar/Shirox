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
// ---- The wrapper: Shirox's module functions, answered by the provider ----
let instance;
function provider() {
  // `Provider` is the provider's class, from the script the app evaluates after this one.
  if (!instance) instance = new Provider(); // eslint-disable-line no-undef
  return instance;
}

// Manga: raw values — Shirox's manga bridge JSON-encodes them itself.
async function mangaSearch(keyword) {
  const results = (await provider().search({ query: keyword })) || [];
  return results.map((r) => ({ title: r.title, image: r.image || "", id: String(r.id) }));
}

function mangaDetails() {
  return { description: "", tags: [] };
}

async function mangaChapters(id) {
  const chapters = (await provider().findChapters(id)) || [];
  const byLanguage = {};
  for (const chapter of chapters) {
    const language = String(chapter.language || "en").toLowerCase();
    const version = { id: String(chapter.id), title: chapter.title || "", scanlation_group: chapter.scanlator || "" };
    const number = parseFloat(chapter.chapter);
    if (!Number.isNaN(number)) version.chapter = number;
    (byLanguage[language] ||= []).push([String(chapter.chapter ?? ""), [version]]);
  }
  return byLanguage;
}

async function mangaImages(id) {
  const pages = (await provider().findChapterPages(id)) || [];
  return pages
    .slice()
    .sort((a, b) => (a.index ?? 0) - (b.index ?? 0))
    .map((page) => ({ url: page.url, headers: page.headers || {} }));
}

// Anime: JSON strings, as Shirox's streaming modules return.
const EPISODE = "seanime-episode:";

function searchMedia(query) {
  const m = globalThis.__seanimeMedia || {};
  return {
    id: m.id ?? 0,
    idMal: m.idMal ?? null,
    status: m.status ?? "",
    format: m.format ?? "",
    englishTitle: m.englishTitle ?? query,
    romajiTitle: m.romajiTitle ?? query,
    episodeCount: m.episodeCount ?? null,
    absoluteSeasonOffset: 0,
    synonyms: m.synonyms ?? [],
    isAdult: m.isAdult ?? false,
    startDate: m.year ? { year: m.year } : null,
  };
}

async function animeSearch(keyword) {
  const media = searchMedia(keyword);
  const results = (await provider().search({ query: keyword, dub: !!host().dub, year: media.startDate?.year, media })) || [];
  return JSON.stringify(results.map((r) => ({ title: r.title, image: "", href: String(r.id) })));
}

function animeDetails() {
  return JSON.stringify([{ description: "", aliases: "", airdate: "" }]);
}

async function animeEpisodes(id) {
  const episodes = (await provider().findEpisodes(id)) || [];
  return JSON.stringify(episodes.map((e) => ({ href: EPISODE + JSON.stringify(e), number: e.number })));
}

function withTimeout(promise, ms) {
  if (typeof setTimeout !== "function") return promise;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timed out")), ms);
    const stop = () => { if (typeof clearTimeout === "function") clearTimeout(timer); };
    promise.then((value) => { stop(); resolve(value); }, (error) => { stop(); reject(error); });
  });
}

async function animeStreams(href) {
  const episode = href.startsWith(EPISODE) ? JSON.parse(href.slice(EPISODE.length)) : { id: href, number: 0, url: href };
  const p = provider();
  const settings = typeof p.getSettings === "function" ? p.getSettings() : null;
  const servers = settings?.episodeServers?.length ? settings.episodeServers : ["default"];
  const failures = [];
  const answers = await Promise.all(servers.map((server) =>
    withTimeout(Promise.resolve().then(() => p.findEpisodeServer(episode, server)), 15000)
      .then((answer) => ({ server, answer }), (error) => {
        failures.push(`${server}: ${(error && error.message) || error}`);
        return null;
      })));

  const streams = [];
  const subtitles = [];
  let subtitleHeaders;
  for (const result of answers) {
    if (!result || !result.answer) continue;
    const { server, answer } = result;
    const headers = answer.headers || {};
    for (const source of answer.videoSources || []) {
      if (!source || !source.url) continue;
      streams.push({
        title: [answer.server || server, source.label || source.quality].filter(Boolean).join(" · "),
        streamUrl: source.url,
        headers,
      });
      for (const sub of source.subtitles || []) {
        if (!sub || !sub.url || subtitles.some((s) => s.url === sub.url)) continue;
        const track = { url: sub.url, title: sub.language || "Subtitle" };
        if (sub.isDefault) { subtitles.unshift(track); subtitleHeaders = headers; } else { subtitles.push(track); }
        if (!subtitleHeaders) subtitleHeaders = headers;
      }
    }
  }
  if (!streams.length) {
    const why = failures.length ? ` (${failures.join("; ")})` : "";
    throw new Error(`None of this provider's servers answered for this episode${why}.`);
  }
  const out = { streams };
  if (subtitles.length) {
    out.subtitle = subtitles[0].url;
    out.allSubtitles = subtitles;
    out.subtitleHeaders = subtitleHeaders || {};
  }
  return JSON.stringify(out);
}

Object.assign(globalThis, {
  searchResults: (keyword) => (host().kind === "anime" ? animeSearch(keyword) : mangaSearch(keyword)),
  extractDetails: (id) => (host().kind === "anime" ? animeDetails(id) : mangaDetails(id)),
  extractChapters: mangaChapters,
  extractImages: mangaImages,
  extractEpisodes: animeEpisodes,
  extractStreamUrl: animeStreams,
});
