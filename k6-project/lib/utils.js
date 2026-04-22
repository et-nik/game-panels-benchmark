import { sleep } from 'k6';

export function thinkTime(min = 1, max = 3) {
  sleep(Math.random() * (max - min) + min);
}

export function randomItem(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}
