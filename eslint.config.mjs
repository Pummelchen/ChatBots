// eslint.config.js — the JavaScript standard for `web/` and the Node check scripts.
//
// Three shapes, because the front end genuinely has three: the page's entry modules are ES
// modules; `deltas.js` and `votes.js` are classic scripts that also work under `require` (the
// Node checks import them); and the check scripts themselves are CommonJS.
//
// The rule set is deliberately small. It catches the defects a reader misses — an undefined
// name, an unused binding, an assignment where a comparison was meant, `var` in a module — and
// leaves formatting to Prettier, which is the one tool that owns it.

import globals from "globals";

const shared = {
  "no-unused-vars": ["error", { argsIgnorePattern: "^_", caughtErrors: "none" }],
  "no-undef": "error",
  "no-redeclare": "error",
  "no-dupe-keys": "error",
  "no-dupe-args": "error",
  "no-cond-assign": ["error", "except-parens"],
  "no-fallthrough": "error",
  "no-self-assign": "error",
  "no-self-compare": "error",
  "no-constant-condition": ["error", { checkLoops: false }],
  "no-unreachable": "error",
  "eqeqeq": ["error", "smart"],
  "no-var": "error",
  "prefer-const": "error",
};

export default [
  {
    ignores: ["node_modules/**", ".build/**", "dist/**", "Sources/**", "promo/**"],
  },
  {
    files: ["web/app.js", "web/app-*.js"],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: "module",
      globals: { ...globals.browser },
    },
    rules: shared,
  },
  {
    // Classic scripts: an IIFE that attaches to the global object and, when it is there, to
    // `module.exports`, which is how the Node checks load them without a browser.
    files: ["web/deltas.js", "web/votes.js"],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: "script",
      globals: { ...globals.browser, ...globals.node },
    },
    rules: shared,
  },
  {
    files: ["tools/check-web-deltas.js", "tools/check-web-votes.js"],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: "commonjs",
      globals: { ...globals.node },
    },
    rules: shared,
  },
];
