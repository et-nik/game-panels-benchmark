// API Write test: start/stop server cycle.
// Tests panel → daemon communication under load.

import http from 'k6/http';
import { check, group, fail, sleep } from 'k6';
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
  thresholds: getThresholds('api_write'),
  tags: {
    panel: panel.key,
    panel_version: panel.version,
    stack: panel.stack,
    scenario: 'api_write',
    profile: __ENV.PROFILE || 'baseline',
  },
};

let vuSession = null;

export function setup() {
  console.log(`=== API Write: ${panel.name} at ${panel.baseUrl} ===`);
  console.log(`Profile: ${profile.description}`);

  const session = setupLogin(panel);
  if (!session) fail(`Login failed for ${panel.name}`);

  // Get server IDs
  const params = getAuthParams(
    session.type === 'needs-vu-login'
      ? { type: 'csrf-session', baseUrl: session.baseUrl }
      : session
  );
  const listRes = http.get(panel.baseUrl + endpoints.listServers(), params);
  let serverIds = [];
  if (listRes.status === 200) {
    try {
      const servers = endpoints.parseServerList(listRes.json());
      serverIds = servers.map(s => endpoints.parseServerId(s));
    } catch (e) { /* */ }
  }
  console.log(`Servers for start/stop: ${serverIds.length} (IDs: ${serverIds.join(', ')})`);

  return { session, serverIds, startedAt: new Date().toISOString() };
}

function ensureSession(data) {
  if (data.session.type === 'bearer-token' || data.session.type === 'api-key') return data.session;
  if (!vuSession) {
    vuSession = vuLogin(panel);
    if (!vuSession) console.error('VU login failed');
  }
  return vuSession;
}

export default function (data) {
  const { serverIds } = data;
  if (!serverIds || serverIds.length === 0) {
    console.error('No servers');
    sleep(5);
    return;
  }

  const session = ensureSession(data);
  if (!session) { thinkTime(1, 2); return; }

  const serverId = randomItem(serverIds);

  group('start_server', function () {
    const params = getAuthParams(session);
    const url = panel.baseUrl + endpoints.serverStart(serverId);
    const res = http.post(url, null, { ...params, tags: { endpoint: 'server_start' } });
    metrics.startDuration.add(res.timings.duration);
    metrics.apiWriteDuration.add(res.timings.duration);
    check(res, { 'start accepted': (r) => r.status >= 200 && r.status < 300 });
  });

  thinkTime(3, 5);

  group('stop_server', function () {
    const params = getAuthParams(session);
    const url = panel.baseUrl + endpoints.serverStop(serverId);
    const res = http.post(url, null, { ...params, tags: { endpoint: 'server_stop' } });
    metrics.stopDuration.add(res.timings.duration);
    metrics.apiWriteDuration.add(res.timings.duration);
    check(res, { 'stop accepted': (r) => r.status >= 200 && r.status < 300 });
  });

  thinkTime(3, 5);
}

export function teardown(data) {
  console.log(`Started:  ${data.startedAt}`);
  console.log(`Finished: ${new Date().toISOString()}`);
}
