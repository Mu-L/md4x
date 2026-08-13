import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Refuse to run against JS artifacts that do not match src/. See the header
    // of scripts/js-artifacts.ts for the two failure modes this catches.
    globalSetup: ["./scripts/js-artifacts.ts"],
  },
});
