# Seanime runtime

What Seanime providers expect of their host, for Shirox's JavaScriptCore engines.

- `src/runtime.js` → `Shirox/Resources/SeanimeRuntime.js`: `LoadDoc` (cheerio with a goquery-style
  adapter), helpers, and the wrapper exposing Shirox's module functions. Loaded before each
  Seanime provider's script.
- `src/install.js` → `Shirox/Resources/SeanimeInstall.js`: TypeScript removal (sucrase), used once
  when a provider is installed.

Build with bun (below 1.4.0): `bun install`, then `bun run build`. Commit the built files.

Bundled libraries, all MIT: cheerio (© Matt Mueller and contributors), buffer (© Feross
Aboukhadijeh), sucrase (© Alan Pierce and contributors).
