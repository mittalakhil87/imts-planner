// Shared helpers for the ExpoWalk serverless functions. No dependencies.
import crypto from 'node:crypto';

export const env = (k, d) => { const v = process.env[k]; if (v === undefined || v === '') { if (d !== undefined) return d; throw new Error('Missing env ' + k); } return v; };
export const json = (res, status, body) => { res.setHeader('Content-Type', 'application/json'); res.setHeader('Cache-Control', 'no-store'); res.status(status).end(JSON.stringify(body)); };

export async function readJson(req) {
  if (req.body && typeof req.body === 'object') return req.body;
  const chunks = []; for await (const c of req) chunks.push(c);
  const s = Buffer.concat(chunks).toString('utf8'); return s ? JSON.parse(s) : {};
}

// ---- Supabase (REST, no client library) ----
const sb = () => ({ url: env('SUPABASE_URL').replace(/\/$/, ''), anon: env('SUPABASE_ANON_KEY'), service: env('SUPABASE_SERVICE_KEY') });

export async function requireUser(req) {
  const auth = req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) { const e = new Error('Sign in first'); e.status = 401; throw e; }
  const { url, anon } = sb();
  const r = await fetch(url + '/auth/v1/user', { headers: { apikey: anon, Authorization: 'Bearer ' + token } });
  if (!r.ok) { const e = new Error('Session expired — sign in again'); e.status = 401; throw e; }
  const u = await r.json(); return { id: u.id, email: (u.email || '').toLowerCase(), token };
}

export async function sbService(path, init = {}) {
  const { url, service } = sb();
  // legacy service_role keys are JWTs and also go in Authorization; new sb_secret_ keys go in apikey only
  const auth = service.startsWith('sb_secret_') ? {} : { Authorization: 'Bearer ' + service };
  const r = await fetch(url + '/rest/v1/' + path, Object.assign({}, init, { headers: Object.assign({ apikey: service, 'Content-Type': 'application/json' }, auth, init.headers || {}) }));
  const txt = await r.text(); let body = null; try { body = txt ? JSON.parse(txt) : null; } catch (e) { body = txt; }
  if (!r.ok) throw new Error('Supabase ' + r.status + ': ' + (body && body.message || txt).slice(0, 300));
  return body;
}

export const rpc = (fn, args) => sbService('rpc/' + fn, { method: 'POST', body: JSON.stringify(args) });

// ---- Google Cloud: short-lived access token from a service-account key (JWT bearer flow) ----
// This broad, "cloud-platform"-scoped token is used SERVER-SIDE ONLY to call the IAM Credentials API
// below. It never leaves this server — see gcpClientToken() for what actually gets handed to a browser.
let cachedToken = null; // {access_token, exp}
async function gcpAccessToken() {
  if (cachedToken && cachedToken.exp - Date.now() > 8 * 60 * 1000) return cachedToken;
  const raw = env('GCP_SA_KEY'); const key = JSON.parse(raw.trim().startsWith('{') ? raw : Buffer.from(raw, 'base64').toString('utf8'));
  const now = Math.floor(Date.now() / 1000);
  const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
  const unsigned = b64({ alg: 'RS256', typ: 'JWT' }) + '.' + b64({ iss: key.client_email, scope: 'https://www.googleapis.com/auth/cloud-platform', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 });
  const sig = crypto.sign('RSA-SHA256', Buffer.from(unsigned), key.private_key).toString('base64url');
  const r = await fetch('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=' + unsigned + '.' + sig });
  const j = await r.json(); if (!r.ok || !j.access_token) throw new Error('Google token error: ' + (j.error_description || j.error || r.status));
  cachedToken = { access_token: j.access_token, exp: Date.now() + (j.expires_in || 3600) * 1000, project: key.project_id, client_email: key.client_email };
  return cachedToken;
}

// ---- Short-lived, per-operation client token (EW-02) ----
// The browser must never see the broad, hour-long, cloud-platform-scoped token above: it would remain a
// valid Vertex AI credential for its whole natural lifetime regardless of what the app's own budget/block
// checks later decide. Instead, every /api/token call impersonates the SAME service account through the
// IAM Credentials API to mint a fresh token good for a few minutes only — long enough to make one Gemini
// call, short enough that a blocked/expired session can't be replayed for long.
// One-time setup this requires (documented in README.md): grant the service account the
// "Service Account Token Creator" role (roles/iam.serviceAccountTokenCreator) ON ITSELF, e.g.
//   gcloud iam service-accounts add-iam-policy-binding <SA_EMAIL> --member="serviceAccount:<SA_EMAIL>" --role="roles/iam.serviceAccountTokenCreator"
export async function gcpClientToken(lifetimeSeconds = 300) {
  const base = await gcpAccessToken();
  const saEmail = process.env.GCP_SA_EMAIL || base.client_email;
  if (!saEmail) throw new Error('Set GCP_SA_EMAIL (the service account\'s own email) so client tokens can be downscoped to a short lifetime.');
  const r = await fetch(`https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${encodeURIComponent(saEmail)}:generateAccessToken`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + base.access_token, 'Content-Type': 'application/json' },
    body: JSON.stringify({ scope: ['https://www.googleapis.com/auth/cloud-platform'], lifetime: Math.max(60, Math.min(3600, lifetimeSeconds)) + 's' })
  });
  const j = await r.json();
  if (!r.ok || !j.accessToken) {
    const msg = (j.error && j.error.message) || r.status;
    throw new Error('Could not mint a short-lived client token (checked GCP_SA_EMAIL has roles/iam.serviceAccountTokenCreator on itself): ' + msg);
  }
  return { access_token: j.accessToken, exp: new Date(j.expireTime).getTime(), project: base.project };
}

export const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
