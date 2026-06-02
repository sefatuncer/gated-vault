import js from '@eslint/js';
import tsParser from '@typescript-eslint/parser';
import tsPlugin from '@typescript-eslint/eslint-plugin';

export default [
  {
    ignores: ['dist/**', 'node_modules/**', 'coverage/**'],
  },
  js.configs.recommended,
  {
    files: ['src/**/*.ts', 'test/**/*.ts'],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        ecmaVersion: 2022,
        sourceType: 'module',
        // Non-type-checked ruleset: no `project` needed. Type-aware rules
        // (e.g. no-floating-promises) get a dedicated tsconfig once the
        // async agent/server handlers land.
      },
    },
    plugins: {
      '@typescript-eslint': tsPlugin,
    },
    rules: {
      ...tsPlugin.configs.recommended.rules,
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      // TypeScript + @types/node resolve globals (console, process, ...) and
      // flag genuine undefined references; the core rule only yields false
      // positives here. This is the typescript-eslint recommended posture.
      'no-undef': 'off',
    },
  },
];
