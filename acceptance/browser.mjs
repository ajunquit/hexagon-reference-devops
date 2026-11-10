import { randomBytes } from 'node:crypto';

const fail = (code) => { throw new Error(`lifecycle.acceptance.${code}`); };
const exactKeys = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).sort().join(',') === keys.sort().join(',');
function https(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.port || url.username || url.password || url.search || url.hash) fail('destinationInvalid');
  return url;
}

export function validateConfiguration(value) {
  if (!exactKeys(value, ['apiVersion', 'instanceId', 'subjectId', 'tenant', 'otherTenant', 'origin', 'apiUrl', 'authentication', 'backend', 'web'])) fail('configurationInvalid');
  if (value.apiVersion !== 'hexagon.ec/browser-acceptance/v1' || !/^run-[1-9][0-9]{0,19}-[1-9][0-9]{0,3}$/.test(value.instanceId) || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value.subjectId)) fail('configurationInvalid');
  if (value.tenant !== `e2e-${value.instanceId}-a` || value.otherTenant !== `e2e-${value.instanceId}-b`) fail('tenantInvalid');
  if (https(value.origin).origin !== value.origin || https(value.apiUrl).pathname !== '/api/v1') fail('destinationInvalid');
  const auth = value.authentication;
  if (!exactKeys(auth, ['authority', 'clientId', 'scope']) || !/^[A-Za-z0-9._-]+$/.test(auth.clientId) || !/^[A-Za-z0-9_.:-]+(?: [A-Za-z0-9_.:-]+)*$/.test(auth.scope) || !auth.scope.split(' ').includes('openid')) fail('identityInvalid');
  if (!/^\/realms\/[A-Za-z0-9._-]+$/.test(https(auth.authority).pathname)) fail('identityAdapterUnsupported');
  if (!exactKeys(value.backend, ['resource', 'receipt', 'seedOperation']) || value.backend.seedOperation !== 'isolated-tenants/v1' || ![value.backend.resource, value.backend.receipt].every((s) => /^[a-z][a-z0-9-]{0,62}$/.test(s))) fail('profileInvalid');
  if (!exactKeys(value.web, ['route', 'selectors']) || !/^\/[a-z][a-z0-9/-]*\/\{tenant\}\/[a-z][a-z0-9/-]*$/.test(value.web.route) || !exactKeys(value.web.selectors, ['signIn', 'code', 'name', 'submit', 'receipt']) || !Object.values(value.web.selectors).every((s) => /^[a-z][a-z0-9-]{0,62}$/.test(s))) fail('profileInvalid');
  return value;
}

export function validateAuthorization(url, config) {
  const expected = `${config.authentication.authority}/protocol/openid-connect/auth`;
  const parsed = new URL(url);
  const p = parsed.searchParams;
  if (`${parsed.origin}${parsed.pathname}` !== expected || p.get('response_type') !== 'code' || p.get('code_challenge_method') !== 'S256' || !/^[A-Za-z0-9_-]{43}$/.test(p.get('code_challenge') ?? '') || !p.get('state') || p.get('client_id') !== config.authentication.clientId || p.get('redirect_uri') !== `${config.origin}/authentication/callback` || p.get('scope') !== config.authentication.scope) fail('pkceMissing');
}

export async function runBrowserAcceptance(chromium, input, credentials) {
  const config = validateConfiguration(input);
  if (!credentials.username || !credentials.password) fail('credentialsMissing');
  const browser = await chromium.launch({ headless: true });
  let context;
  try {
    // No HAR, traces, screenshots, videos, persistent profile or storageState containing tokens.
    context = await browser.newContext({ serviceWorkers: 'block' });
    const apiOrigin = new URL(config.apiUrl).origin;
    const issuerOrigin = new URL(config.authentication.authority).origin;
    const allowed = new Set([config.origin, apiOrigin, issuerOrigin]);
    let blocked = false;
    await context.route('**/*', async (route) => {
      const request = route.request();
      const destination = new URL(request.url());
      if (destination.protocol !== 'https:' || !allowed.has(destination.origin) || (request.headers().authorization && destination.origin !== apiOrigin)) {
        // Public third-party decorative assets are unnecessary for the journey; block without sending data.
        if (request.headers().authorization || request.method() !== 'GET' || !['font', 'image', 'stylesheet'].includes(request.resourceType())) blocked = true;
        await route.abort(); return;
      }
      await route.continue();
    });
    const page = await context.newPage();
    page.setDefaultTimeout(30000);
    const route = config.web.route.replace('{tenant}', config.tenant);
    await page.goto(config.origin + route);
    const authorize = page.waitForURL((u) => `${u.origin}${u.pathname}` === `${config.authentication.authority}/protocol/openid-connect/auth`);
    await page.getByTestId(config.web.selectors.signIn).click();
    await authorize;
    validateAuthorization(page.url(), config);
    const action = await page.locator('#kc-form-login').getAttribute('action');
    const actionUrl = new URL(action, page.url());
    if (actionUrl.origin !== issuerOrigin || !actionUrl.pathname.startsWith(new URL(config.authentication.authority).pathname + '/login-actions/')) fail('loginDestinationChanged');
    await page.locator('#username').fill(credentials.username);
    await page.locator('#password').fill(credentials.password);
    await page.locator('#kc-login').click();
    await page.waitForURL(config.origin + route);
    const runtime = await page.evaluate(async () => {
      const response = await fetch('/runtime-config.json', { cache: 'no-store', redirect: 'error', credentials: 'omit' });
      if (response.status !== 200) return null;
      return response.json();
    });
    if (!runtime || runtime.apiUrl !== config.apiUrl || JSON.stringify(runtime.authentication) !== JSON.stringify(config.authentication)) {
      // Compare fields semantically: public JSON member order is not significant.
      if (!runtime || runtime.apiUrl !== config.apiUrl || !exactKeys(runtime.authentication, ['authority', 'clientId', 'scope']) || Object.keys(config.authentication).some((k) => runtime.authentication[k] !== config.authentication[k])) fail('publicConfigurationChanged');
    }
    const resource = `${config.apiUrl}/${config.tenant}/${config.backend.resource}`;
    await page.getByTestId(config.web.selectors.code).fill(`E2E${randomBytes(6).toString('hex')}`);
    await page.getByTestId(config.web.selectors.name).fill('Acceptance customer');
    const createdResponse = page.waitForResponse((r) => r.url() === resource && r.request().method() === 'POST');
    await page.getByTestId(config.web.selectors.submit).click();
    const created = await createdResponse;
    if (created.status() !== 201) fail('creationFailed');
    const { id } = await created.json();
    if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id ?? '')) fail('createdIdInvalid');
    const authorization = (await created.request().allHeaders()).authorization;
    if (!authorization?.startsWith('Bearer ')) fail('bearerMissing');
    const claims = JSON.parse(Buffer.from(authorization.slice(7).split('.')[1], 'base64url').toString('utf8'));
    // The API validates the signature. Here the real UI request must use the seeded test subject.
    if (claims.sub !== config.subjectId || claims.iss !== config.authentication.authority) fail('subjectChanged');
    const receiptUrl = `${resource}/${id}/${config.backend.receipt}`;

    // A fast worker may have completed before waitForResponse was installed. Inspect the DOM first.
    const receipt = page.getByTestId(config.web.selectors.receipt);
    await receipt.locator('xpath=self::*[@data-completed="true"][@data-customer-id="' + id + '"]').waitFor({ timeout: 65000 });
    // Read through the browser with the same Bearer to prove persisted reaction and row isolation.
    const facts = await page.evaluate(async ({ own, other, bearer }) => {
      const read = (url) => fetch(url, { headers: { Authorization: bearer }, credentials: 'omit', redirect: 'error', cache: 'no-store' });
      const ownResponse = await read(own); const otherResponse = await read(other);
      return { status: ownResponse.status, receipt: ownResponse.status === 200 ? await ownResponse.json() : null, otherStatus: otherResponse.status };
    }, { own: receiptUrl, other: `${config.apiUrl}/${config.otherTenant}/${config.backend.resource}/${id}/${config.backend.receipt}`, bearer: authorization });

    if (facts.status !== 200 || facts.receipt?.customerId !== id || facts.receipt?.completed !== true || !Number.isFinite(Date.parse(facts.receipt?.completedAt)) || facts.otherStatus !== 404) fail('reactionOrIsolationFailed');
    if (blocked) fail('unexpectedNetworkDestination');
    return { apiVersion: 'hexagon.ec/browser-acceptance-result/v1', status: 'Succeeded', pkce: true, authenticatedCreate: true, workerReaction: true, tenantIsolation: true };
  } finally {
    if (context) await context.close();
    await browser.close();
  }
}
