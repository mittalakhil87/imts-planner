// POST /api/email { subject, text, html?, dedupe? } — relays the minutes the phone already has to the
// signed-in user's own address. Opt-in only. The text is passed straight to the mail provider and is not
// stored or logged here. Rate-limited and duplicate-send-protected per account (EW-10) — the recipient is
// always the authenticated user's own verified address, never a client-supplied address.
import { env, json, readJson, requireUser, esc, rpc } from './_lib.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'POST only' });
  if (!process.env.RESEND_API_KEY) return json(res, 503, { error: 'Email is not configured' });
  let user; try { user = await requireUser(req); } catch (e) { return json(res, e.status || 500, { error: e.message }); }
  let body; try { body = await readJson(req); } catch (e) { return json(res, 400, { error: 'Bad JSON' }); }
  const dedupe = body.dedupe ? String(body.dedupe).slice(0, 80) : null;
  let rate; try { rate = await rpc('check_email_rate', { p_user: user.id, p_dedupe: dedupe }); } catch (e) { return json(res, 500, { error: 'Rate check failed: ' + e.message }); }
  if (!rate || !rate.ok) {
    const msg = { blocked: 'This account has been paused. Contact info@expowalk.app.', rate_hour: 'Too many emails sent in the last hour — try again shortly.', rate_day: 'Daily email limit reached for this account.' }[rate && rate.reason] || 'Not allowed';
    return json(res, 429, { error: msg, reason: rate && rate.reason });
  }
  if (rate.duplicate) return json(res, 200, { ok: true, to: user.email, duplicate: true });
  const subject = String(body.subject || 'ExpoWalk minutes').slice(0, 200);
  const text = String(body.text || ''); if (!text.trim()) return json(res, 400, { error: 'Nothing to send' });
  if (text.length > 400000) return json(res, 413, { error: 'Too long' });
  const from = process.env.MAIL_FROM || 'ExpoWalk <notes@expowalk.app>';
  const html = `<div style="font-family:Arial,sans-serif;max-width:720px;margin:0 auto;color:#1b2026"><pre style="white-space:pre-wrap;font:14px/1.5 Arial,sans-serif">${esc(text)}</pre><p style="color:#7b838d;font-size:12px;margin-top:24px">Sent by ExpoWalk to the address on your account, at your request. This email was relayed, not stored. ${esc(process.env.APP_URL || 'https://expowalk.app')}</p></div>`;
  const r = await fetch('https://api.resend.com/emails', { method: 'POST', headers: { Authorization: 'Bearer ' + env('RESEND_API_KEY'), 'Content-Type': 'application/json' }, body: JSON.stringify({ from, to: [user.email], subject, text, html }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) return json(res, 502, { error: 'Mail provider error: ' + (j.message || r.status) });
  return json(res, 200, { ok: true, to: user.email });
}
