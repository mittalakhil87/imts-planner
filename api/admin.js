// GET /api/admin — owner only: sign-ups, usage, estimated spend. POST { shared_enabled?, max_free_users?, budget_usd?, block?: {id, blocked} } to change settings.
import { json, readJson, requireUser, sbService } from './_lib.js';

export default async function handler(req, res) {
  let user; try { user = await requireUser(req); } catch (e) { return json(res, e.status || 500, { error: e.message }); }
  const owner = (process.env.OWNER_EMAIL || '').toLowerCase().split(',').map(s => s.trim()).filter(Boolean);
  if (!owner.includes(user.email)) return json(res, 403, { error: 'Owner only' });
  if (req.method === 'GET' && /(^|[?&])probe=1/.test(req.url || '')) return json(res, 200, { owner: true }); // cheap 'am I the owner?' check used by the app
  try {
    if (req.method === 'POST') {
      const b = await readJson(req);
      if (b.block && b.block.id) await sbService(`profiles?id=eq.${encodeURIComponent(b.block.id)}`, { method: 'PATCH', body: JSON.stringify({ blocked: !!b.block.blocked }), headers: { Prefer: 'return=minimal' } });
      const patch = {}; for (const k of ['shared_enabled', 'max_free_users', 'budget_usd', 'cap_meetings', 'cap_scans', 'cap_seconds']) if (b[k] !== undefined) patch[k] = b[k];
      if (Object.keys(patch).length) await sbService('settings?id=eq.1', { method: 'PATCH', body: JSON.stringify(patch), headers: { Prefer: 'return=minimal' } });
    }
    const [settings] = await sbService('settings?id=eq.1&select=*');
    const profiles = await sbService('profiles?select=id,email,name,company,designation,phone,country,consent_at,free_slot,meetings_used,scans_used,seconds_used,blocked,created_at&order=created_at.desc&limit=2000');
    const est = settings.total_meetings * Number(settings.cost_meeting_usd) + settings.total_scans * Number(settings.cost_scan_usd);
    return json(res, 200, { settings, estimated_spend_usd: Math.round(est * 100) / 100, users: profiles.length, active: profiles.filter(p => p.meetings_used || p.scans_used).length, profiles });
  } catch (e) { return json(res, 500, { error: e.message }); }
}
