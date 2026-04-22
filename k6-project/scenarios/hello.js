// Smoke-test: panel responds on /login with HTTP 200.

import http from 'k6/http';
import { check } from 'k6';
import { getPanel } from '../config/panels.js';
import { getProfile } from '../config/stages.js';
import { thinkTime } from '../lib/utils.js';

const panel = getPanel();
const profile = getProfile();
const smokeUrl = panel.baseUrl + (panel.paths.smoke || '/login');

export const options = {
  stages: profile.stages,
  tags: {
    panel: panel.key,
    panel_version: panel.version,
    stack: panel.stack,
    scenario: 'hello',
    profile: __ENV.PROFILE || 'baseline',
  },
};

export function setup() {
  console.log(`=== Testing ${panel.name} at ${smokeUrl} ===`);
  console.log(`Profile: ${profile.description}`);
  return { startedAt: new Date().toISOString() };
}

export default function () {
  const res = http.get(smokeUrl);
  check(res, {
    'status 200': (r) => r.status === 200,
  });
  thinkTime(1, 2);
}

export function teardown(data) {
  console.log(`Started:  ${data.startedAt}`);
  console.log(`Finished: ${new Date().toISOString()}`);
}
