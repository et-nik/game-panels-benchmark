export const COMMON_THRESHOLDS = {
  http_req_failed: ['rate<0.01'],
  http_req_duration: ['p(95)<500', 'p(99)<1500'],
  checks: ['rate>0.99'],
};

export const SCENARIO_THRESHOLDS = {
  api_read: { ...COMMON_THRESHOLDS },
  api_write: {
    ...COMMON_THRESHOLDS,
    http_req_duration: ['p(95)<2000'],
  },
  auth_test: {
    ...COMMON_THRESHOLDS,
    http_req_duration: ['p(95)<3000'], // bcrypt is slow
  },
  stress: {
    http_req_failed: ['rate<0.5'],
  },
};

export function getThresholds(scenarioType = 'api_read') {
  const profile = __ENV.PROFILE || '';
  if (profile.startsWith('stress')) return SCENARIO_THRESHOLDS.stress;
  return SCENARIO_THRESHOLDS[scenarioType] || COMMON_THRESHOLDS;
}
