import { defineConfig } from "@hey-api/openapi-ts";
import { fileURLToPath } from "node:url";

const packageTsConfigPath = fileURLToPath(new URL("./tsconfig.json", import.meta.url));

export default defineConfig({
  input: "../../apps/phoenix/priv/api/openapi.yaml",
  output: {
    path: "src/client",
    tsConfigPath: packageTsConfigPath,
  },
  plugins: [
    "@hey-api/client-ky",
    "valibot",
    {
      name: "@hey-api/typescript",
      enums: "javascript",
      comments: true,
    },
    {
      name: "@hey-api/sdk",
      validator: true,
    },
    {
      name: "@tanstack/svelte-query",
      queryKeys: true,
      queryOptions: true,
      mutationKeys: true,
      mutationOptions: true,
    },
  ],
});
