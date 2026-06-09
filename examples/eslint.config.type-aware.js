// Example type-aware ESLint config for the checkup `type-aware-lint` check.
//
// Copy to your project root as `eslint.config.type-aware.js`. This is a
// SEPARATE, slower config from your default lint pass — it needs the
// TypeScript project service, which is why checkup runs it as its own (opt-in)
// section. checkup skips the section entirely if this file is absent.
//
// checkup invokes: npx eslint -c eslint.config.type-aware.js
//
// Requires (install in your project): typescript-eslint
//   npm i -D typescript-eslint

import tseslint from "typescript-eslint";

export default tseslint.config({
  files: ["**/*.ts", "**/*.tsx"],
  languageOptions: {
    parserOptions: {
      // Type-aware rules need the project service to resolve types.
      projectService: true,
    },
  },
  rules: {
    // The headline reason to run a type-aware pass: `||` silently drops
    // `0`, `''` and `false`, so prefer `??` where those are valid values.
    "@typescript-eslint/prefer-nullish-coalescing": "error",
    // A few other high-signal type-aware rules worth gating on:
    "@typescript-eslint/no-floating-promises": "error",
    "@typescript-eslint/no-misused-promises": "error",
    "@typescript-eslint/await-thenable": "error",
  },
});
