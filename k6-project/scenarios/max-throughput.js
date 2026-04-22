// Max Throughput test: no think-time, maximum RPS.
// Shows the real capacity ceiling of each panel.

import http from 'k6/http';
import { check, group } from 'k6';
import { getPanel } from '../config/panels.js';
import { getEndpoints } from '../config/endpoints.js';
import { setupLogin, vuLogin, getAuthParams } from '../lib/auth.js';
import { metrics } from '../lib/metrics.js';
import { randomItem } from '../lib/utils.js';

const panel = getPanel();
const endpoints = getEndpoints(panel.key);

// Custom stages from env or default ramp to target VUs
const TARGET_VUS = parseInt(__ENV.TARGET_VUS || '100');
const DURATION = __ENV.DURATION || '2m';

export const options = {
  scenarios: {
    max_rps: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: TARGET_VUS },
        { duration: DURATION, target: TARGET_VUS },
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '10s',
      gracefulStop: '10s',
    },
  },
  tags: {
    panel: panel.key,
    panel_version: panel.version,
    stack: panel.stack,
    scenario: 'max_throughput',
    profile: `${TARGET_VUS}vus`,
  },
};

let vuSession = null;

export function setup() {
  console.log(`=== Max Throughput: ${panel.name} at ${panel.baseUrl} ===`);
  console.log(`Target: ${TARGET_VUS} VUs, duration: ${DURATION}, NO think-time`);

  const session = setupLogin(panel);
  if (!session) {
    console.error('Login failed');
    return { session: null };
  }

  return { session: session, startedAt: new Date().toISOString() };
}

function ensureSession(data) {
  if (data.session.type === 'bearer-token' || data.session.type === 'api-key') {
    return data.session;
  }
  if (!vuSession) {
    vuSession = vuLogin(panel);
  }
  return vuSession;
}

export default function (data) {
  const session = ensureSession(data);
  if (!session) return;

  const params = getAuthParams(session);

  // 1. List servers — NO sleep between requests
  let servers = [];
  const listUrl = panel.baseUrl + endpoints.listServers();
  const listRes = http.get(listUrl, { ...params, tags: { endpoint: 'list_servers' } });
  metrics.listDuration.add(listRes.timings.duration);

  if (listRes.status === 200) {
    try { servers = endpoints.parseServerList(listRes.json()); } catch (e) { /* */ }
  }

  if (servers.length === 0) return;

  const server = randomItem(servers);
  const serverId = endpoints.parseServerId(server);

  // 2. Server details — immediate
  const detUrl = panel.baseUrl + endpoints.serverDetails(serverId);
  const detRes = http.get(detUrl, { ...params, tags: { endpoint: 'server_details' } });
  metrics.detailsDuration.add(detRes.timings.duration);

  // 3. Server status — immediate
  const statUrl = panel.baseUrl + endpoints.serverStatus(serverId);
  const statRes = http.get(statUrl, { ...params, tags: { endpoint: 'server_status' } });
  metrics.statusDuration.add(statRes.timings.duration);

  // Count successful
  check(listRes, { 'list ok': (r) => r.status === 200 });
  check(detRes, { 'details ok': (r) => r.status === 200 });
  check(statRes, { 'status ok': (r) => r.status === 200 });
}

export function teardown(data) {
  console.log(`Started:  ${data.startedAt}`);
  console.log(`Finished: ${new Date().toISOString()}`);
}
