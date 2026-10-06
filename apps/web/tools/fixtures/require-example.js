import { createRequire } from "node:module";

export const example = "createRequire(import.meta.url)";
export const resolver = createRequire(import.meta.url);
