# ExpoWalk — IMTS 2026 floor planner

Plan which booths to visit, walk the halls with a map, record booth conversations, scan visiting cards and paper notes — and get AI minutes.
**Everything you record stays on your phone.** Processing goes from your phone straight to Google's Gemini API; ExpoWalk's server never receives audio, photos, transcripts or minutes.

Live: https://expowalk.app (planner at https://expowalk.app/imts2026)

## What is where

| Data | Where it lives |
|---|---|
| Recordings, card & note photos, transcripts, minutes, stars, notes, visits | Your phone's browser storage (IndexedDB / localStorage). Never uploaded by the app. |
| Audio / photos during processing | Sent by your phone directly to Google (Gemini on Vertex AI, paid tier — not used for training). Either with your own key, or with a 1-hour token that ExpoWalk's server hands out. |
| Name, email, company, designation, phone, consent, usage counters | ExpoWalk's database (Supabase), only if you sign in. |
| Minutes email | Opt-in. Relayed through `api/email.js` to your own address at that moment; not stored. |

Nothing else. No analytics, no tracking scripts.

## Repository layout

- `index.html` — landing page (what ExpoWalk is, shows, how it works, privacy, free-allowance sign-up).
- `imts2026.html` — the IMTS 2026 planner app (single file: data, maps, UI, logic), served at `/imts2026`.
- `api/config.js` — public config (Supabase URL/key, allowance limits).
- `api/token.js` — checks the caller's free allowance (Supabase `use_quota`), mints a short-lived Google access token, returns it. No audio passes through.
- `api/email.js` — opt-in relay of minutes to the signed-in user's own address (Resend).
- `api/admin.js` — owner-only: sign-ups, usage, spend, switches.
- `supabase/schema.sql` — tables, quota function, row-level security.

## Environment variables (Vercel → Project → Settings → Environment Variables)

| Name | Value |
|---|---|
| `SUPABASE_URL` | `https://<ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | anon / publishable key |
| `SUPABASE_SERVICE_KEY` | service_role (legacy JWT) or `sb_secret_…` key |
| `GCP_SA_KEY` | the service-account JSON (or base64 of it) — role *Vertex AI User* only |
| `GCP_PROJECT` | Google Cloud project id (optional, taken from the key) |
| `GCP_LOCATION` | `us-central1` (default) or `global` |
| `GEMINI_MODEL` | `gemini-2.5-flash` |
| `RESEND_API_KEY` | Resend key with sending access |
| `MAIL_FROM` | `ExpoWalk <notes@expowalk.app>` |
| `OWNER_EMAIL` | comma-separated owner logins for `/api/admin` and `#admin` |
| `APP_URL` | `https://expowalk.app` |

Redeploy after changing variables.

## Free allowance

First `max_free_users` (default 100) profiles with consent get `cap_meetings` recordings (25), `cap_scans` card/note scans (300) and `cap_seconds` of audio (8 h). A global `budget_usd` (500) stops the shared token when the estimated spend is reached. All adjustable from `#admin` in the app or the `settings` row in Supabase. Beyond the allowance the user pastes their own Gemini key — the app then never touches ExpoWalk's server at all.
