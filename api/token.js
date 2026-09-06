// POST /api/token { kind: 'audio'|'card'|'note', seconds?: number, item: string }
// Reserves the caller's free allowance (without yet charging it — see confirm.js) and returns a
// short-lived (few-minute) Google access token so the PHONE can call Gemini on Vertex AI directly.
// Audio and photos never pass through this server. The token is intentionally NOT the broad,
// hour-long service-account credential — see gcpClientToken() in _lib.js for why (EW-02).
import { json, readJson, requireUser, rpc, gcpClientToken } from './_lib.js';

const REASONS = {
  no_profile: 'Complete your profile first (Account).',
  blocked: 'This account has been paused. Contact info@expowalk.app.',
  disabled: 'The free ExpoWalk allowance is switched off right now — use your own Gemini key (Settings).',
  no_free_slot: 'The free allowance was for the first sign-ups and is fully taken — use your own Gemini key (Settings), it is free from Google.',
  no_consent: 'Tick "ExpoWalk may contact me" in your profile to activate the free allowance, or use your own Gemini key (Settings).',
  budget: 'The free allowance for this show has been used up — use your own Gemini key (Settings).',
  cap_meetings: 'You have used all your free recordings — use your own Gemini key (Settings) for the rest.',
  cap_seconds: 'You have used all your free recording hours — use your own Gemini key (Settings) for the rest.',
  cap_scans: 'You have used all your free card/note scans — use your own Gemini key (Settings) for the rest.'
};

export default async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'POST only' });
  let user; try { user = await requireUser(req); } catch (e) { return json(res, e.status || 500, { error: e.message }); }
  let body; try { body = await readJson(req); } catch (e) { return json(res, 400, { error: 'Bad JSON' }); }
  const kind = ['audio', 'card', 'note'].includes(body.kind) ? body.kind : null; if (!kind) return json(res, 400, { error: 'kind required' });
  const item = String(body.item || '').slice(0, 64); if (!item) return json(res, 400, { error: 'item required' });
  const seconds = Math.max(0, Math.min(6 * 3600, Math.round(Number(body.seconds) || 0)));
  if (kind === 'audio' && seconds > 3 * 3600) return json(res, 400, { error: 'Recordings over 3 hours are not covered by the free allowance.' });
  let q; try { q = await rpc('reserve_quota', { p_user: user.id, p_kind: kind, p_seconds_est: seconds, p_item: item }); }
  catch (e) { return json(res, 500, { error: 'Quota check failed: ' + e.message }); }
  if (!q || !q.ok) return json(res, 402, { error: REASONS[q && q.reason] || 'Not allowed', reason: q && q.reason });
  if (q.already_done) return json(res, 200, { done: true, remaining: q.remaining });
  let tk; try { tk = await gcpClientToken(300); } catch (e) { return json(res, 500, { error: e.message }); }
  const location = process.env.GCP_LOCATION || 'us-central1';
  const project = process.env.GCP_PROJECT || tk.project;
  const endpoint = location === 'global' ? 'https://aiplatform.googleapis.com' : `https://${location}-aiplatform.googleapis.com`;
  return json(res, 200, { access_token: tk.access_token, expires_at: tk.exp, project, location, endpoint, model: process.env.GEMINI_MODEL || 'gemini-2.5-flash', remaining: q.remaining, retry: !!q.retry });
}
