import { defineConfig } from 'vitest/config'

export default defineConfig({
  base: './',
  plugins: [
    {
      // The dev server injects styles and opens a reload socket, which the shipped CSP blocks.
      name: 'drop-csp-in-dev',
      apply: 'serve',
      transformIndexHtml: html => html.replace(/\s*<meta http-equiv="Content-Security-Policy"[^>]*>/, ''),
    },
  ],
  build: {
    // The page only runs in the WebKit of macOS 26, so nothing needs lowering for older browsers.
    target: 'safari18',
    outDir: 'dist',
    emptyOutDir: true,
    modulePreload: { polyfill: false },
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['test/setup.ts'],
  },
})
