// Runs before the libraries: `entities` (in cheerio) decodes its tables with `atob` as it loads,
// and a bare JSContext has none — without these, loading throws.
import { Buffer } from "buffer";

globalThis.Buffer ??= Buffer;
if (typeof globalThis.atob !== "function") globalThis.atob = (s) => Buffer.from(String(s), "base64").toString("binary");
if (typeof globalThis.btoa !== "function") globalThis.btoa = (s) => Buffer.from(String(s), "binary").toString("base64");
