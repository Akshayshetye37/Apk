# Aurelia AI Gateway

This optional Cloudflare Worker provides online, model-backed guidance to Aurelia PMS. The Android app never contains the provider API key. PMS data is not sent to the gateway; the app sends only the user's explicit assistant question.

## Deploy

1. Install Node.js and Wrangler: `npm install -g wrangler`.
2. From this directory, authenticate: `wrangler login`.
3. Deploy: `wrangler deploy`.
4. Set secrets (do not commit them):
   - `wrangler secret put OPENAI_API_KEY` — your OpenAI API key.
   - `wrangler secret put AURELIA_GATEWAY_TOKEN` — a long, random, revocable bearer token.
5. Apply rate limiting to the Worker in Cloudflare before sharing it with production devices. Monitor provider usage and configure a spending limit.
6. In Aurelia PMS > Settings > Internet & AI automation, enable Internet and AI, enter the deployed HTTPS Worker URL, enter the gateway token, and save.

The app stores the gateway token using Android secure storage. Never use a provider API key as the gateway token. Rotate the gateway token if a device is lost.

## Contract and safety

- POST JSON: `{"question":"How do I reconcile room food charges?"}`
- Header: `Authorization: Bearer <AURELIA_GATEWAY_TOKEN>`
- Success: `{"answer":"...","model":"..."}`
- Only the explicit question is forwarded; no database rows, guest identity data, invoices, or order records are sent.
- The model advises only. It cannot directly alter records, post charges, or run repairs.
- If the gateway is missing, disabled, offline, or fails, the app falls back to built-in offline guidance.
- `store: false` is requested from the model API; review your provider's current data handling terms before production use.
- The worker's bearer token is a basic access gate. Configure Cloudflare rate limiting and monitor usage before production use.

## Limitations

Deploying this Worker and configuring its secrets is a separate hosting step; committing this source does not deploy it. Online AI remains unavailable until a real HTTPS endpoint and valid secrets are configured. Local PMS workflows must continue to work without it.
