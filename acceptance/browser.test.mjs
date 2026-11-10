import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { validateConfiguration, validateAuthorization, runBrowserAcceptance } from './browser.mjs';

const config = {
  apiVersion: 'hexagon.ec/browser-acceptance/v1', instanceId: 'run-123-1', subjectId: '55555555-5555-4555-8555-555555555555',
  tenant: 'e2e-run-123-1-a', otherTenant: 'e2e-run-123-1-b', origin: 'https://web.example.test', apiUrl: 'https://api.example.test/api/v1',
  authentication: { authority: 'https://identity.example.test/realms/hexagon', clientId: 'web', scope: 'openid profile api.all' },
  backend: { resource: 'customers', receipt: 'welcome', seedOperation: 'isolated-tenants/v1' },
  web: { route: '/sales/{tenant}/customers', selectors: { signIn: 'sso-sign-in', code: 'customer-code', name: 'customer-name', submit: 'customer-create', receipt: 'customer-welcome' } },
};
const authorize = new URL(config.authentication.authority + '/protocol/openid-connect/auth');
for (const [key, value] of Object.entries({ response_type: 'code', code_challenge_method: 'S256', code_challenge: 'a'.repeat(43), state: 'fixture-state', client_id: 'web', redirect_uri: config.origin + '/authentication/callback', scope: config.authentication.scope })) authorize.searchParams.set(key, value);

test('configuration rejects foreign tenants, insecure destinations and executable profile fields', () => {
  assert.equal(validateConfiguration(structuredClone(config)).tenant, config.tenant);
  for (const change of [{ tenant: 'existing-tenant' }, { otherTenant: config.tenant }, { apiUrl: 'http://api.example.test/api/v1' }, { origin: 'https://web.example.test/path' }, { command: 'arbitrary' }, { web: { ...config.web, route: '//other.test/{tenant}/customers' } }]) {
    assert.throws(() => validateConfiguration({ ...config, ...change }));
  }
});

test('authorization requires Code, S256, state and the exact public callback/client/scope', () => {
  validateAuthorization(authorize.href, config);
  for (const [key, value] of [['code_challenge_method', 'plain'], ['response_type', 'token'], ['state', ''], ['redirect_uri', 'https://foreign.test/callback'], ['client_id', 'other'], ['scope', 'openid']]) {
    const changed = new URL(authorize); changed.searchParams.set(key, value);
    assert.throws(() => validateAuthorization(changed.href, config), /pkceMissing/);
  }
});

// A native Chromium DOM/protocol fixture. These intercepted endpoints are NOT Azure, real OIDC,
// a backend or a broker, and their success is never published as cloud application evidence.
function fixtureBrowser({ otherStatus = 404, completed = true, subject = config.subjectId, withBearer = true } = {}) {
  const id = '019a6d5b-88f8-7000-8000-000000000001';
  const token = ['fixture', Buffer.from(JSON.stringify({ sub: subject, iss: config.authentication.authority })).toString('base64url'), 'fixture'].join('.');
  let polls = 0;
  const serve = async (route) => {
    const request = route.request(); const url = new URL(request.url());
    const json = (value, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': config.origin, 'Access-Control-Allow-Headers': 'authorization, content-type', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' }, body: JSON.stringify(value) });
    if (request.method() === 'OPTIONS') return json({});
    if (url.origin === config.origin && url.pathname === '/runtime-config.json') return json({ apiUrl: config.apiUrl, authentication: config.authentication });
    if (url.origin === new URL(config.apiUrl).origin) {
      if (request.method() === 'POST') return json({ id }, 201);
      if (url.pathname.includes(config.otherTenant)) return json({ code: 'customers.notFound' }, otherStatus);
      polls++;
      return json({ customerId: id, completed: completed && polls > 1, completedAt: completed && polls > 1 ? '2026-11-10T00:00:00Z' : null });
    }
    if (url.origin === new URL(config.authentication.authority).origin) {
      if (request.method() === 'POST') return route.fulfill({ contentType: 'text/html', body: '<script>location.replace(' + JSON.stringify(config.origin + '/authentication/callback') + ')</script>' });
      return route.fulfill({ contentType: 'text/html', body: `<form id="kc-form-login" method="post" action="${config.authentication.authority}/login-actions/authenticate"><input id="username" name="username"><input id="password" name="password" type="password"><button id="kc-login">Sign in</button></form>` });
    }
    if (url.pathname === '/authentication/callback') {
      return route.fulfill({ contentType: 'text/html', body: `<input data-testid="customer-code"><input data-testid="customer-name"><button data-testid="customer-create">Create</button><p data-testid="customer-welcome" data-completed="false"></p>
        <script>
          history.replaceState(null, '', ${JSON.stringify(config.web.route.replace('{tenant}', config.tenant))});
          document.querySelector('button').onclick = async () => {
            const headers = { 'Content-Type': 'application/json', ${withBearer ? `Authorization: ${JSON.stringify('Bearer ' + token)}` : ''} };
            const resource = ${JSON.stringify(`${config.apiUrl}/${config.tenant}/${config.backend.resource}`)};
            const response = await fetch(resource, { method: 'POST', headers, body: '{}' });
            const { id } = await response.json();
            const receipt = document.querySelector('p'); receipt.dataset.customerId = id;
            const poll = async () => {
              const result = await (await fetch(resource + '/' + id + '/welcome', { headers })).json();
              // Test a dishonest DOM as well: persisted HTTP evidence must still reject it.
              receipt.dataset.completed = String(result.completed || ${!completed}); receipt.textContent = 'Processed';
              if (!result.completed && ${completed}) setTimeout(poll, 10);
            }; await poll();
          };
        </script>` });
    }
    return route.fulfill({ contentType: 'text/html', body: `<button data-testid="sso-sign-in" onclick="location.href='${authorize.href.replaceAll('&', '&amp;')}'">Sign in</button>` });
  };
  return { launch: async (options) => {
    const browser = await chromium.launch(options);
    return new Proxy(browser, { get(target, property) {
      if (property === 'newContext') return async (contextOptions) => {
        const context = await browser.newContext(contextOptions);
        return new Proxy(context, { get(value, member) {
          if (member === 'route') return async (pattern, handler) => context.route(pattern, (route) => handler({ request: () => route.request(), abort: () => route.abort(), continue: () => serve(route) }));
          const selected = value[member]; return typeof selected === 'function' ? selected.bind(value) : selected;
        } });
      };
      const selected = target[property]; return typeof selected === 'function' ? selected.bind(target) : selected;
    } });
  } };
}

test('native browser adapter drives UI login, creation, delayed worker receipt and tenant isolation', async () => {
  const result = await runBrowserAcceptance(fixtureBrowser(), config, { username: 'fixture-user', password: 'fixture-password' });
  assert.equal(result.status, 'Succeeded'); assert.equal(result.tenantIsolation, true);
});

test('a completed DOM cannot replace the persisted worker receipt', async () => {
  await assert.rejects(runBrowserAcceptance(fixtureBrowser({ completed: false }), config, { username: 'fixture-user', password: 'fixture-password' }), /reactionOrIsolationFailed/);
});

test('a cross-tenant 200 or a different token subject fails the journey', async () => {
  await assert.rejects(runBrowserAcceptance(fixtureBrowser({ otherStatus: 200 }), config, { username: 'fixture-user', password: 'fixture-password' }), /reactionOrIsolationFailed/);
  await assert.rejects(runBrowserAcceptance(fixtureBrowser({ subject: 'other-user' }), config, { username: 'fixture-user', password: 'fixture-password' }), /subjectChanged/);
});

test('a simulated session without the real UI Bearer is rejected', async () => {
  await assert.rejects(runBrowserAcceptance(fixtureBrowser({ withBearer: false }), config, { username: 'fixture-user', password: 'fixture-password' }), /bearerMissing/);
});
