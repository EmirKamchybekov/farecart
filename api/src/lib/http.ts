import type { Context } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import type { ZodType } from 'zod';

/** Error that maps straight to an HTTP response. */
export class ApiError extends Error {
  readonly status: ContentfulStatusCode;
  readonly code: string;
  readonly details: unknown;

  constructor(status: ContentfulStatusCode, code: string, message: string, details?: unknown) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export type ErrorBody = {
  error: { code: string; message: string; details?: unknown };
};

export function errorBody(code: string, message: string, details?: unknown): ErrorBody {
  return details === undefined ? { error: { code, message } } : { error: { code, message, details } };
}

/** Validate c.req.query() against a zod schema; throws a 400 ApiError with field-level details. */
export function parseQuery<T>(c: Context, schema: ZodType<T>): T {
  const result = schema.safeParse(c.req.query());
  if (!result.success) {
    const details = result.error.issues.map((i) => ({
      param: i.path.join('.') || undefined,
      message: i.message,
    }));
    throw new ApiError(400, 'bad_request', 'Invalid query parameters', details);
  }
  return result.data;
}

export type FetchJsonOptions = RequestInit & { timeoutMs?: number };

/**
 * fetch() that enforces a timeout, parses JSON, and turns non-2xx into an ApiError
 * (502 upstream_error) so route handlers stay small.
 */
export async function fetchJson<T>(
  url: string | URL,
  upstreamName: string,
  options: FetchJsonOptions = {},
): Promise<T> {
  const { timeoutMs = 8000, ...init } = options;
  let res: Response;
  try {
    res = await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  } catch (err) {
    const timedOut = err instanceof Error && err.name === 'TimeoutError';
    throw new ApiError(
      504,
      timedOut ? 'upstream_timeout' : 'upstream_unreachable',
      timedOut ? `${upstreamName} did not respond in time` : `Could not reach ${upstreamName}`,
    );
  }
  const text = await res.text();
  let body: unknown = null;
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = text.slice(0, 300);
    }
  }
  if (!res.ok) {
    throw new ApiError(502, 'upstream_error', `${upstreamName} returned HTTP ${res.status}`, body);
  }
  return body as T;
}

export const TEN_MINUTES = 'public, max-age=600, s-maxage=600, stale-while-revalidate=60';
