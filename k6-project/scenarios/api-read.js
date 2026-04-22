// API Read test: list servers → details → status.
// Three core REST API operations that every panel user performs.
//
// Auth strategy:
//   GameAP 3.x (csrf-session): login per-VU (cookies don't transfer from setup)
//   GameAP 4.x (bearer-token): login once in setup, reuse token

import http from 'k6/http';
import { check, group, fail } from 'k6';
import { getPanel } from '../config/panels.js';
import { getProfile } from '../config/stages.js';
import { getThresholds } from '../config/thresholds.js';
import { getEndpoints } from '../config/endpoints.js';
import { setupLogin, vuLogin, getAuthParams } from '../lib/auth.js';
import { metrics } from '../lib/metrics.js';
import { thinkTime, randomItem } from '../lib/utils.js';

const panel = getPanel();
const profile = getProfile();
const endpoints = getEndpoints(panel.key);

export const options = {
  stages: profile.stages,
  thresholds: getThresholds('api_read'),
  tags: {
    panel: panel.key,
    panel_version: panel.version,
    stack: panel.stack,
    scenario: 'api_read',
    profile: __ENV.PROFILE || 'baseline',
  },
};

// Per-VU session (persists across iterations within same VU)
let vuSession = null;

export function setup() {
  console.log(`=== API Read: ${panel.name} at ${panel.baseUrl} ===`);
  console.log(`Profile: ${profile.description}`);

  const session = setupLogin(panel);
  if (!session) fail(`Login failed for ${panel.name}`);

  // Count servers (using setup session — works for both auth types here)
  const params = getAuthParams(
    session.type === 'needs-vu-login'
      ? { type: 'csrf-session', baseUrl: session.baseUrl }
      : session
  );
  const listRes = http.get(panel.baseUrl + endpoints.listServers(), params);
  let serverCount = 0;
  if (listRes.status === 200) {
    try {
      serverCount = endpoints.parseServerList(listRes.json()).length;
    } catch (e) { /* */ }
  }
  console.log(`Servers found: ${serverCount}`);

  return { session: session, startedAt: new Date().toISOString() };
}

function ensureSession(data) {
  // For bearer-token or api-key: session from setup() is sufficient
  if (data.session.type === 'bearer-token' || data.session.type === 'api-key') {
    return data.session;
  }

  // For cookie/csrf-session: need per-VU login (cookies are VU-scoped)
  if (!vuSession) {
    vuSession = vuLogin(panel);
    if (!vuSession) {
      console.error('VU login failed');
      return null;
    }
  }
  return vuSession;
}

export default function (data) {
  const session = ensureSession(data);
  if (!session) {
    thinkTime(1, 2);
    return;
  }

  // 1. List servers
  let servers = [];
  group('list_servers', function () {
    const params = getAuthParams(session);
    const url = panel.baseUrl + endpoints.listServers();
    let res = http.get(url, { ...params, tags: { endpoint: 'list_servers' } });

    // Re-login on 401 (session expired) for cookie-session panels
    if (res.status === 401 && (session.type === 'cookie-session' || session.type === 'csrf-session')) {
      vuSession = vuLogin(panel);
      if (vuSession) {
        const freshParams = getAuthParams(vuSession);
        res = http.get(url, { ...freshParams, tags: { endpoint: 'list_servers' } });
      }
    }

    metrics.listDuration.add(res.timings.duration);
    metrics.apiReadDuration.add(res.timings.duration);

    const ok = check(res, { 'list 200': (r) => r.status === 200 });
    metrics.errors.add(!ok);

    if (ok) {
      try { servers = endpoints.parseServerList(res.json()); } catch (e) { /* */ }
    }
  });

  if (servers.length === 0) {
    thinkTime(1, 2);
    return;
  }

  thinkTime(0.3, 0.8);

  // 2. Server details
  const server = randomItem(servers);
  const serverId = endpoints.parseServerId(server);

  group('server_details', function () {
    const params = getAuthParams(session);
    const url = panel.baseUrl + endpoints.serverDetails(serverId);
    const res = http.get(url, { ...params, tags: { endpoint: 'server_details' } });
    metrics.detailsDuration.add(res.timings.duration);
    metrics.apiReadDuration.add(res.timings.duration);

    check(res, { 'details 200': (r) => r.status === 200 });
  });

  thinkTime(0.3, 0.8);

  // 3. Server status
  group('server_status', function () {
    const params = getAuthParams(session);
    const url = panel.baseUrl + endpoints.serverStatus(serverId);
    const res = http.get(url, { ...params, tags: { endpoint: 'server_status' } });
    metrics.statusDuration.add(res.timings.duration);
    metrics.apiReadDuration.add(res.timings.duration);

    check(res, { 'status 200': (r) => r.status === 200 });
  });

  thinkTime(1, 3);
}

export function teardown(data) {
  console.log(`Started:  ${data.startedAt}`);
  console.log(`Finished: ${new Date().toISOString()}`);
}
