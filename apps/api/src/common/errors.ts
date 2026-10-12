import { HttpException, HttpStatus } from '@nestjs/common';

export class AppError extends HttpException {
  constructor(status: HttpStatus, code: string, message: string, extra?: Record<string, unknown>) {
    super({ statusCode: status, code, message, ...extra }, status);
  }
}

export const forbidden = (code: string, message = 'Forbidden') => new AppError(HttpStatus.FORBIDDEN, code, message);
export const notFound = (what = 'Resource') => new AppError(HttpStatus.NOT_FOUND, 'not_found', `${what} not found`);
export const conflict = (code: string, message: string) => new AppError(HttpStatus.CONFLICT, code, message);
export const badRequest = (code: string, message: string) => new AppError(HttpStatus.BAD_REQUEST, code, message);
export const unauthorized = (code = 'unauthorized', message = 'Unauthorized') =>
  new AppError(HttpStatus.UNAUTHORIZED, code, message);

/** Explicit marker for work that is intentionally not built yet. */
export class NotImplementedError extends AppError {
  constructor(feature: string) {
    super(HttpStatus.NOT_IMPLEMENTED, 'not_implemented', `NotImplemented: ${feature}`);
  }
}
