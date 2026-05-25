import { defineConfig } from "@hey-api/openapi-ts";

export default defineConfig({
  input: "../../apps/phoenix/priv/api/openapi.yaml",
  output: "src/client",
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
