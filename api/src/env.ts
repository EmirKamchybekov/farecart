import { ApiError } from './lib/http.js';

export function optionalEnv(name: string): string | undefined {
  const v = process.env[name]?.trim();
  return v ? v : undefined;
}

export function requireEnv(name: string): string {
  const v = optionalEnv(name);
  if (!v) {
    throw new ApiError(500, 'misconfigured', `Server is missing the ${name} environment variable`);
  }
  return v;
}
