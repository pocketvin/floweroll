import { defineConfig } from '@playwright/test';

// Test server owns a separate port; no dependency on a personal Host or Task DB.
const externalURL = process.env.OBSERVATORY_TEST_URL;
const baseURL = externalURL || 'http://127.0.0.1:3044';
export default defineConfig({
  testDir: './tests', timeout: 30000, fullyParallel: false, workers: 1,
  forbidOnly: !!process.env.CI, retries: 0,
  outputDir: '../../../work/observability-browser/artifacts',
  reporter: [['list'], ['json', { outputFile: '../../../work/observability-browser/results.json' }]],
  webServer: externalURL ? undefined : {
    command: 'npm exec vite -- --host 127.0.0.1 --port 3044 --strictPort',
    url: baseURL, reuseExistingServer: false, timeout: 30000,
  },
  use: { baseURL, channel: process.env.OBSERVATORY_BROWSER_CHANNEL || 'chrome', headless: true,
    viewport: { width: 1440, height: 960 }, screenshot: 'only-on-failure', trace: 'retain-on-failure' },
});
