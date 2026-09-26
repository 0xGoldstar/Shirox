// Install-time tools: TypeScript to JavaScript, once, when a provider is installed.
import { transform } from "sucrase";

globalThis.__seanimeStripTypeScript = (code) =>
  transform(code, { transforms: ["typescript"], disableESTransforms: true }).code;
