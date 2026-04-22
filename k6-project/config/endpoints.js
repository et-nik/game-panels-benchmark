// API endpoint mapping for each panel.
// One scenario works with all panels via these adapters.

export const ENDPOINTS = {
  'gameap-3': {
    listServers:      () => '/api/servers',
    serverDetails:    (id) => `/api/servers/${id}`,
    serverStatus:     (id) => `/api/servers/${id}`,       // No separate status endpoint in 3.x
    serverConsole:    (id) => `/api/servers/${id}/console`,
    serverStart:      (id) => `/api/servers/${id}/start`,
    serverStop:       (id) => `/api/servers/${id}/stop`,
    createServer:     () => '/api/servers/',

    parseServerList:  (body) => Array.isArray(body) ? body : (body.data || []),
    parseServerId:    (item) => item.id,
  },
  'gameap-4': {
    listServers:      () => '/api/servers',
    serverDetails:    (id) => `/api/servers/${id}`,
    serverStatus:     (id) => `/api/servers/${id}/status`,
    serverConsole:    (id) => `/api/servers/${id}/console`,
    serverStart:      (id) => `/api/servers/${id}/start`,
    serverStop:       (id) => `/api/servers/${id}/stop`,
    createServer:     () => '/api/servers',

    parseServerList:  (body) => Array.isArray(body) ? body : (body.data || []),
    parseServerId:    (item) => item.id,
  },
  'pterodactyl': {
    listServers:      () => '/api/client',
    serverDetails:    (id) => `/api/client/servers/${id}`,
    serverStatus:     (id) => `/api/client/servers/${id}/resources`,
    serverConsole:    (id) => `/api/client/servers/${id}/websocket`,
    serverStart:      (id) => `/api/client/servers/${id}/power`,
    serverStop:       (id) => `/api/client/servers/${id}/power`,
    createServer:     () => '/api/application/servers',

    parseServerList:  (body) => body.data || [],
    parseServerId:    (item) => item.attributes.identifier,
  },
  'pelican': {
    listServers:      () => '/api/client',
    serverDetails:    (id) => `/api/client/servers/${id}`,
    serverStatus:     (id) => `/api/client/servers/${id}/resources`,
    serverConsole:    (id) => `/api/client/servers/${id}/websocket`,
    serverStart:      (id) => `/api/client/servers/${id}/power`,
    serverStop:       (id) => `/api/client/servers/${id}/power`,
    createServer:     () => '/api/application/servers',

    parseServerList:  (body) => body.data || [],
    parseServerId:    (item) => item.attributes.identifier,
  },
  'pufferpanel': {
    listServers:      () => '/api/servers',
    serverDetails:    (id) => `/api/servers/${id}`,
    serverStatus:     (id) => `/api/servers/${id}/status`,
    serverConsole:    (id) => `/api/servers/${id}/stats`,
    serverStart:      (id) => `/api/servers/${id}/start`,
    serverStop:       (id) => `/api/servers/${id}/stop`,
    createServer:     () => '/api/servers',

    parseServerList:  (body) => body.servers || [],
    parseServerId:    (item) => item.id,
  },
};

export function getEndpoints(panelKey) {
  const e = ENDPOINTS[panelKey];
  if (!e) throw new Error(`No endpoints for panel: ${panelKey}`);
  return e;
}
