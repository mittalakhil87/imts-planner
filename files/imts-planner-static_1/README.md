# IMTS 2026 Floor Planner — static site (no backend)

One file: `index.html`. Host it anywhere static (Vercel, Netlify, Cloudflare Pages, GitHub Pages, any web server).
- No server code, no database, no accounts. Nothing a visitor does leaves their phone except the transcription call,
  which goes directly from the phone to Google Gemini under the visitor's own API key (entered in Meetings → Settings).
- Recordings are stored in the phone's browser storage (IndexedDB) and can be downloaded/shared from the Meetings tab.
- Must be served over HTTPS (microphone access requires a secure origin). Vercel/Netlify do this automatically.

Deploy on Vercel: New Project → "Other" framework → upload this folder (or connect a repo containing it) → Deploy →
Settings → Domains → add e.g. imts.<your-domain> and the CNAME it shows.
