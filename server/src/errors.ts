/** An error that maps directly to an HTTP response `{ error: code, message }`. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: Record<string, unknown>,
  ) {
    super(message);
  }
}

export const badRequest = (msg: string, details?: Record<string, unknown>) => new HttpError(400, "bad_request", msg, details);
export const notFound = (msg = "Not found") => new HttpError(404, "not_found", msg);
export const conflict = (msg: string, details?: Record<string, unknown>) => new HttpError(409, "conflict", msg, details);
