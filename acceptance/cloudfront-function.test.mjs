import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const module = readFileSync(new URL('../terraform/modules/hosting/aws/web.tf', import.meta.url), 'utf8');
const source = module.match(/code\s*=\s*<<-EOT\r?\n([\s\S]*?)\r?\n\s*EOT/);
assert.ok(source, 'The hosting module must define the CloudFront Function.');
const handler = runInNewContext(`${source[1]}\nhandler`);

test('the actual CloudFront Function rewrites SPA routes and preserves static files', () => {
  for (const uri of ['/', '/customers', '/customers/new']) {
    assert.equal(handler({ request: { uri } }).uri, '/index.html');
  }
  for (const uri of ['/runtime-config.json', '/main-HASH.js', '/assets/logo.png']) {
    assert.equal(handler({ request: { uri } }).uri, uri);
  }
});
