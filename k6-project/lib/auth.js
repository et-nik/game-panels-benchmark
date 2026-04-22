import http from 'k6/http';
import { check } from 'k6';

// ======================================================
// GameAP 3.x: Laravel CSRF + Session cookies
// IMPORTANT: Must be called within VU context (default function),
// NOT in setup(), because cookies don't transfer between contexts.
// ======================================================

export function loginGameAP3(baseUrl, login, password) {
  const loginPage = http.get(`${baseUrl}/login`);
  if (loginPage.status !== 200) {
    console.error(`GameAP3 login page: ${loginPage.status}`);
    return null;
  }

  const jar = http.cookieJar();
  const cookies = jar.cookiesForURL(baseUrl);
  const xsrfEncoded = cookies['XSRF-TOKEN'] ? cookies['XSRF-TOKEN'][0] : null;
  if (!xsrfEncoded) {
    console.error('GameAP3: no XSRF-TOKEN cookie');
    return null;
  }
  const xsrfToken = decodeURIComponent(xsrfEncoded);

  const loginRes = http.post(
    `${baseUrl}/api/auth/login`,
    JSON.stringify({ login: login, password: password, remember: 'on' }),
    {
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-XSRF-TOKEN': xsrfToken,
        'X-Requested-With': 'XMLHttpRequest',
      },
    }
  );

  const ok = check(loginRes, {
    'gameap3 login success': (r) => r.status === 200 || r.status === 204,
  });

  if (!ok) {
    console.error(`GameAP3 login failed: ${loginRes.status}`);
    return null;
  }

  return { type: 'csrf-session', baseUrl: baseUrl };
}

export function gameap3Params(session) {
  const jar = http.cookieJar();
  const cookies = jar.cookiesForURL(session.baseUrl);
  const xsrfEncoded = cookies['XSRF-TOKEN'] ? cookies['XSRF-TOKEN'][0] : '';
  const xsrfToken = decodeURIComponent(xsrfEncoded);

  return {
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-XSRF-TOKEN': xsrfToken,
      'X-Requested-With': 'XMLHttpRequest',
    },
    timeout: '30s',
  };
}


// ======================================================
// GameAP 4.x: Bearer PASETO token (stateless)
// Can be called in setup() — token is just a string.
// ======================================================

export function loginGameAP4(baseUrl, login, password) {
  const loginRes = http.post(
    `${baseUrl}/api/auth/login`,
    JSON.stringify({ login: login, password: password }),
    {
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    }
  );

  const ok = check(loginRes, {
    'gameap4 login success': (r) => r.status === 200,
  });

  if (!ok) {
    console.error(`GameAP4 login failed: ${loginRes.status} — ${loginRes.body}`);
    return null;
  }

  let token = '';
  try {
    const body = loginRes.json();
    token = body.token || body.access_token || body.data?.token || '';
  } catch (e) {
    console.error(`GameAP4 parse error: ${e}`);
    return null;
  }

  if (!token) {
    console.error('GameAP4: empty token');
    return null;
  }

  return { type: 'bearer-token', token: token, baseUrl: baseUrl };
}

export function gameap4Params(session) {
  return {
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${session.token}`,
    },
    timeout: '30s',
  };
}


// ======================================================
// PufferPanel: OAuth2 Client Credentials
// One token request in setup(), reuse for all VUs.
// ======================================================

export function loginOAuth2(baseUrl, clientId, clientSecret) {
  const loginRes = http.post(
    `${baseUrl}/oauth2/token`,
    `grant_type=client_credentials&client_id=${clientId}&client_secret=${clientSecret}`,
    {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
      },
    }
  );

  const ok = check(loginRes, {
    'oauth2 token success': (r) => r.status === 200,
  });

  if (!ok) {
    console.error(`OAuth2 login failed: ${loginRes.status} — ${loginRes.body}`);
    return null;
  }

  let token = '';
  try {
    const body = loginRes.json();
    token = body.access_token || '';
  } catch (e) {
    console.error(`OAuth2 parse error: ${e}`);
    return null;
  }

  if (!token) {
    console.error('OAuth2: empty access_token');
    return null;
  }

  return { type: 'bearer-token', token: token, baseUrl: baseUrl };
}


// ======================================================
// Universal helpers
// ======================================================

export function apiKeyParams(session) {
  return {
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${session.token}`,
    },
    timeout: '30s',
  };
}

export function getAuthParams(session) {
  if (session.type === 'csrf-session') return gameap3Params(session);
  if (session.type === 'bearer-token') return gameap4Params(session);
  if (session.type === 'api-key') return apiKeyParams(session);
  throw new Error(`Unknown session type: ${session.type}`);
}

// Setup-phase login: verify credentials, return session or marker
export function setupLogin(panel) {
  const { key, baseUrl, testUser, authType, auth } = panel;

  // API key auth — simplest, works for any panel
  if (authType === 'api-key' && auth && auth.clientToken) {
    console.log(`Using API key for ${panel.name}`);
    return { type: 'api-key', token: auth.clientToken, baseUrl: baseUrl };
  }

  // OAuth2 Client Credentials (PufferPanel)
  if (authType === 'oauth2' && auth && auth.clientId) {
    const session = loginOAuth2(baseUrl, auth.clientId, auth.clientSecret);
    if (!session) return null;
    console.log(`OAuth2 token obtained for ${panel.name}`);
    return session;
  }

  // GameAP 3.x CSRF session (fallback if no api-key configured)
  if (key === 'gameap-3') {
    const session = loginGameAP3(baseUrl, testUser.login, testUser.password);
    if (!session) return null;
    console.log('Login verified (csrf-session — will re-login per VU)');
    return { type: 'needs-vu-login', authType: 'csrf-session', baseUrl: baseUrl };
  }

  // GameAP 4.x Bearer token (fallback if no api-key configured)
  if (key === 'gameap-4') {
    const session = loginGameAP4(baseUrl, testUser.login, testUser.password);
    if (!session) return null;
    console.log('Login OK (bearer-token)');
    return session;
  }

  console.error(`Login not implemented: ${key}`);
  return null;
}

// VU-context login (called once per VU lifetime)
export function vuLogin(panel) {
  // API key — no login needed, just return token
  if (panel.authType === 'api-key' && panel.auth && panel.auth.clientToken) {
    return { type: 'api-key', token: panel.auth.clientToken, baseUrl: panel.baseUrl };
  }

  // OAuth2 — token from setup() works for all VUs, but if needed:
  if (panel.authType === 'oauth2' && panel.auth && panel.auth.clientId) {
    return loginOAuth2(panel.baseUrl, panel.auth.clientId, panel.auth.clientSecret);
  }

  if (panel.key === 'gameap-3') {
    return loginGameAP3(panel.baseUrl, panel.testUser.login, panel.testUser.password);
  }
  if (panel.key === 'gameap-4') {
    return loginGameAP4(panel.baseUrl, panel.testUser.login, panel.testUser.password);
  }
  return null;
}
