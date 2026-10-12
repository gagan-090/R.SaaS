# contracts

The API contract that Aditya's screens build against. **Generated — do not edit by hand.**

- `openapi.json` — OpenAPI 3 document produced from the running Nest app. It covers every route, its auth, its request-body schema (derived from the same zod schema the server validates with) and the recorded examples.
- `fixtures/*.json` — one real request/response per endpoint (plus some error examples), recorded by driving the API end to end. `fixtures/INDEX.md` lists them all. Tokens and secrets are replaced with `<placeholders>`.

Regenerate after any API change (needs the dev DB running):

```bash
pnpm --filter @rsaas/api openapi
```

Any contract change is a PR to this folder, tagged for both Gagan and Aditya (Kitchen Playbook §02).
