import { Rate, Trend, Counter } from 'k6/metrics';

export const metrics = {
  errors:           new Rate('errors'),
  apiReadDuration:  new Trend('api_read_duration', true),
  apiWriteDuration: new Trend('api_write_duration', true),
  loginDuration:    new Trend('login_duration', true),
  listDuration:     new Trend('list_servers_duration', true),
  detailsDuration:  new Trend('server_details_duration', true),
  statusDuration:   new Trend('server_status_duration', true),
  consoleDuration:  new Trend('server_console_duration', true),
  startDuration:    new Trend('server_start_duration', true),
  stopDuration:     new Trend('server_stop_duration', true),
};
