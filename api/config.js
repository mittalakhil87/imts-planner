// GET /api/config — public configuration for the app (nothing secret here).
import { env, json } from './_lib.js';
export default async function handler(req, res) {
  let limits = null;
  try {
    const r = await fetch(env('SUPABASE_URL').replace(/\/$/, '') + '/rest/v1/limits?select=*', { headers: { apikey: env('SUPABASE_ANON_KEY') } });
    if (r.ok) limits = (await r.json())[0] || null;
  } catch (e) { /* app still works without the account layer */ }
  json(res, 200, {
    supabaseUrl: env('SUPABASE_URL').replace(/\/$/, ''), anonKey: env('SUPABASE_ANON_KEY'),
    model: process.env.GEMINI_MODEL || 'gemini-2.5-flash',
    shared: limits ? { enabled: !!limits.shared_enabled, maxFreeUsers: limits.max_free_users, capMeetings: limits.cap_meetings, capScans: limits.cap_scans, capSeconds: limits.cap_seconds, freeSlotsTaken: Number(limits.free_slots_taken || 0) } : { enabled: false },
    email: !!process.env.RESEND_API_KEY, appUrl: process.env.APP_URL || ''
  });
}
