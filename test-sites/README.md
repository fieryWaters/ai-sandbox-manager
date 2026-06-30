# Test Sites

Each env file holds only the URL-specific overrides for a test clone of YouArtStudiosWeb. Everything else is copied from the production `.env`, which lives in the deployment checkout inside the `youart-agent-base` LXD box at:

```text
/home/agent/deployments/YouArtStudiosWeb-13bd5b0/.env
```

## Deploy Recipe

Clone the YouArtStudiosWeb repo into a deployment directory inside an LXD box, copy the production `.env`, then append one test-site override file:

```sh
cat testN.env >> .env
docker compose down && docker compose up --build -d
```

Dotenv uses last-key-wins behavior, so the appended `testN.env` values override the copied production values.

## Constraints

Host ports `18000` and `18080` are hardcoded in the app compose file, so run at most one test stack per LXD box. Use `sandbox copy` to clone boxes for parallel test sites.

`TUNNEL_TOKEN` is per-site for the Cloudflare tunnel from `testN.jacob-waters.com` to `http://web:80`.

`GOOGLE_CLIENT_ID` is a per-site sandbox OAuth client.
