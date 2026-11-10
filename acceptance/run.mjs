import fs from 'node:fs';
import { chromium } from 'playwright';
import { runBrowserAcceptance } from './browser.mjs';

try {
  if (process.argv.length !== 3 || fs.statSync(process.argv[2]).size > 16384) throw new Error();
  const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const username = process.env.HEXAGON_E2E_USERNAME;
  const password = process.env.HEXAGON_E2E_PASSWORD;
  delete process.env.HEXAGON_E2E_USERNAME; delete process.env.HEXAGON_E2E_PASSWORD;
  const result = await runBrowserAcceptance(chromium, input, { username, password });
  process.stdout.write(JSON.stringify(result));
} catch {
  // Browser exceptions may contain URLs, credentials, headers and page content.
  process.stdout.write(JSON.stringify({ apiVersion: 'hexagon.ec/browser-acceptance-result/v1', status: 'Failed', code: 'lifecycle.acceptance.browserFailed' }));
  process.exitCode = 1;
}
