// Load profiles. Switch with PROFILE=smoke|baseline|load|stress|soak

export const PROFILES = {
  smoke: {
    stages: [{ duration: '30s', target: 1 }],
    description: 'Smoke — 1 VU, 30s',
  },
  baseline: {
    stages: [
      { duration: '1m', target: 10 },
      { duration: '3m', target: 10 },
      { duration: '30s', target: 0 },
    ],
    description: 'Baseline — 10 VUs steady, 4.5m',
  },
  load: {
    stages: [
      { duration: '1m', target: 20 },
      { duration: '2m', target: 50 },
      { duration: '5m', target: 100 },
      { duration: '2m', target: 100 },
      { duration: '1m', target: 0 },
    ],
    description: 'Load — ramp to 100 VUs',
  },
  stress: {
    stages: [
      { duration: '1m', target: 50 },
      { duration: '2m', target: 100 },
      { duration: '2m', target: 200 },
      { duration: '2m', target: 400 },
      { duration: '2m', target: 800 },
      { duration: '1m', target: 0 },
    ],
    description: 'Stress — ramp to 800 VUs',
  },
  'stress-1000': {
    stages: [
      { duration: '1m', target: 200 },
      { duration: '1m', target: 500 },
      { duration: '1m', target: 1000 },
      { duration: '5m', target: 1000 },
      { duration: '1m', target: 0 },
    ],
    description: 'Stress — ramp to 1000 VUs',
  },
  'stress-1200': {
    stages: [
      { duration: '1m', target: 200 },
      { duration: '1m', target: 500 },
      { duration: '1m', target: 800 },
      { duration: '1m', target: 1200 },
      { duration: '5m', target: 1200 },
      { duration: '1m', target: 0 },
    ],
    description: 'Stress — ramp to 1200 VUs',
  },
  soak: {
    stages: [
      { duration: '2m', target: 50 },
      { duration: '4h', target: 50 },
      { duration: '2m', target: 0 },
    ],
    description: 'Soak — 4h at 50 VUs',
  },
};

export function getProfile() {
  const name = __ENV.PROFILE || 'baseline';
  if (!PROFILES[name]) {
    throw new Error(`Unknown profile: ${name}. Valid: ${Object.keys(PROFILES).join(', ')}`);
  }
  return PROFILES[name];
}
