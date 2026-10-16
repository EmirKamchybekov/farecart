// Local dev entry: `npm run dev`. Loads ../.env.local (repo root) or ./.env.local, then serves on PORT.
import { serve } from '@hono/node-server';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import app from './app.js';

for (const candidate of ['../../.env.local', '../.env.local', '../.env']) {
  const p = resolve(import.meta.dirname, candidate);
  if (existsSync(p)) {
    process.loadEnvFile(p);
    break;
  }
}

const port = Number(process.env.PORT ?? 3000);
serve({ fetch: app.fetch, port }, (info) => {
  console.log(`farecart-api listening on http://localhost:${info.port}`);
});
