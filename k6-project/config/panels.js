// Configuration of every panel under test.
// Switch with PANEL=gameap-3|gameap-4|pterodactyl|pelican

const PANELS = {
  'gameap-3': {
    name: 'GameAP 3.x',
    version: '3.x',
    stack: 'PHP',
    baseUrl: __ENV.GAMEAP3_URL || 'http://10.10.10.10',
    authType: 'api-key',
    paths: {
      smoke: '/login',
    },
    auth: {
      clientToken: __ENV.GAMEAP3_API_TOKEN || '<GAMEAP3_API_KEY>
    },
    // Kept for auth-test scenario (login performance)
    testUser: {
      login: __ENV.GAMEAP3_LOGIN || 'admin',
      password: __ENV.GAMEAP3_PASSWORD || 'Wo1yJQ3G75de0Ut8',
    },
  },
  'gameap-4': {
    name: 'GameAP 4.x',
    version: '4.x',
    stack: 'Go',
    baseUrl: __ENV.GAMEAP4_URL || 'http://10.10.10.11',
    authType: 'api-key',
    paths: {
      smoke: '/login',
    },
    auth: {
      clientToken: __ENV.GAMEAP4_API_TOKEN || '<GAMEAP4_API_KEY>
    },
    // Kept for auth-test scenario (login performance)
    testUser: {
      login: __ENV.GAMEAP4_LOGIN || 'admin',
      password: __ENV.GAMEAP4_PASSWORD || 'Cx3Z50Guw716fdJa',
    },
  },
  'pterodactyl': {
    name: 'Pterodactyl',
    version: '1.11.x',
    stack: 'PHP',
    baseUrl: __ENV.PTERO_URL || 'http://10.10.10.12',
    authType: 'api-key', // Static Bearer token, no login needed
    paths: {
      smoke: '/auth/login',
    },
    auth: {
      clientToken: __ENV.PTERO_CLIENT_TOKEN || '<PTERODACTYL_API_KEY>
    },
  },
  'pelican': {
    name: 'Pelican',
    version: '1.0.x',
    stack: 'PHP',
    baseUrl: __ENV.PELICAN_URL || 'http://10.10.10.13',
    authType: 'api-key', // Static Bearer token, no login needed
    paths: {
      smoke: '/login',
    },
    auth: {
      clientToken: __ENV.PELICAN_CLIENT_TOKEN || '<PELICAN_CLIENT_KEY>
      appToken: __ENV.PELICAN_APP_TOKEN || '<PELICAN_APP_KEY>
    },
  },
  'pufferpanel': {
    name: 'PufferPanel',
    version: '3.x',
    stack: 'Go',
    baseUrl: __ENV.PUFFER_URL || 'http://10.10.10.14:8080',
    authType: 'oauth2',
    paths: {
      smoke: '/auth/login',
    },
    auth: {
      clientId: __ENV.PUFFER_CLIENT_ID || '<PUFFERPANEL_CLIENT_ID>
      clientSecret: __ENV.PUFFER_CLIENT_SECRET || '<PUFFERPANEL_CLIENT_SECRET>
    },
  },
};

export function getPanel() {
  const name = __ENV.PANEL;
  if (!name) {
    throw new Error('PANEL env var required: gameap-3|gameap-4|pterodactyl|pelican|pufferpanel');
  }
  if (!PANELS[name]) {
    throw new Error(`Unknown panel: ${name}. Valid: ${Object.keys(PANELS).join(', ')}`);
  }
  const panel = PANELS[name];
  if (!panel.baseUrl) {
    throw new Error(`${name}: baseUrl is empty`);
  }
  return { key: name, ...panel };
}

export { PANELS };
