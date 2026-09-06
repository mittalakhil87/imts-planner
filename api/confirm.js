// POST /api/confirm { item: string, success: boolean, seconds?: number }
// Tells the server what actually happened after the phone called Gemini directly with the token from
// /api/token, so usage is charged on the real outcome instead of at token-issue time (EW-02, EW-19):
// a failed or abandoned attempt costs nothing, and audio must report a real (>0) duration to be charged.
// Also best-effort revokes the short-lived token so it cannot be reused after this operation is done,
// shrinking its reuse window from its few-minute natural expiry to effectively "right now" (EW-02).
import { json, readJson, requireUser, rpc } from './_lib.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'POST only' });
  let user; try { user = await requireUser(req); } catch (e) { return json(res, e.status || 500, { error: e.message }); }
  let body; try { body = await readJson(req); } catch (e) { return json(res, 400, { error: 'Bad JSON' }); }
  const item = String(body.item || '').slice(0, 64); if (!item) return json(res, 400, { error: 'item required' });
  const success = !!body.success;
  const seconds = Math.max(0, Math.min(3 * 3600, Math.round(Number(body.seconds) || 0)));
  let q; try { q = await rpc('confirm_quota', { p_user: user.id, p_item: item, p_actual_seconds: seconds, p_success: success }); }
  catch (e) { return json(res, 500, { error: 'Confirm failed: ' + e.message }); }
  if (body.token) { try { await fetch('https://oauth2.googleapis.com/revoke?token=' + encodeURIComponent(body.token), { method: 'POST' }); } catch (e) { /* best-effort */ } }
  if (!q || !q.ok) return json(res, 200, { ok: false, reason: q && q.reason });
  return json(res, 200, { ok: true, charged: !!q.charged, remaining: q.remaining });
}
