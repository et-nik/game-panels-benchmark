// Auth performance test: each iteration does a full login cycle.
// GameAP 3.x: GET /login (CSRF) + POST /api/auth/login (bcrypt + session)
// GameAP 4.x: POST /api/auth/login (bcrypt + PASETO token)

import { check, fail } from 'k6';
import { getPanel } from '../config/panels.js';
import { getProfile } from '../config/stages.js';
import { getThresholds } from '../config/thresholds.js';
import { vuLogin } from '../lib/auth.js';
import { metrics } from '../lib/metrics.js';
import { thinkTime } from '../lib/utils.js';

const panel = getPanel();
const profile = getProfile();

export const options = {
  stages: profile.stages,
  thresholds: getThresholds('auth_test'),
  tags: {
    panel: panel.key,
    panel_version: panel.version,
    stack: panel.stack,
    scenario: 'auth_test',
    profile: __ENV.PROFILE || 'baseline',
  },
};

export function setup() {
  console.log(`=== Auth Test: ${panel.name} at ${panel.baseUrl} ===`);
  console.log(`Profile: ${profile.description}`);

  // Verify login works
  const session = vuLogin(panel);
  if (!session) fail(`Pre-test login failed for ${panel.name}`);
  console.log(`Pre-test login OK (type: ${session.type})`);

  return { startedAt: new Date().toISOString() };
}

export default function () {
  const start = Date.now();

  const session = vuLogin(panel);

  const duration = Date.now() - start;
  metrics.loginDuration.add(duration);

  const ok = check(session, {
    'login successful': (s) => s !== null,
  });
  metrics.errors.add(!ok);

  thinkTime(1, 2);
}

export function teardown(data) {
  console.log(`Started:  ${data.startedAt}`);
  console.log(`Finished: ${new Date().toISOString()}`);
}
