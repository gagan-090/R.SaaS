import { PipeTransform } from '@nestjs/common';
import { z } from 'zod';
import { badRequest } from './errors';

/** Validates a request body/query with zod; 400 lists the failing fields. */
export class ZodPipe<T extends z.ZodType> implements PipeTransform {
  constructor(private readonly schema: T) {}
  transform(value: unknown): z.infer<T> {
    const r = this.schema.safeParse(value ?? {});
    if (!r.success) {
      throw badRequest('validation_failed', r.error.issues.map((i) => `${i.path.join('.') || 'body'}: ${i.message}`).join('; '));
    }
    return r.data;
  }
}
export const zbody = <T extends z.ZodType>(s: T) => new ZodPipe(s);

/** OpenAPI request-body schema derived from the same zod schema the route validates with. */
export const apiBody = (s: z.ZodType) => ({
  schema: z.toJSONSchema(s, { target: 'openapi-3.0', unrepresentable: 'any', io: 'input' }) as Record<string, unknown>,
});
