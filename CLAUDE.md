# RULES - NEVER BREAK THESE

## Deploy Rules
- NEVER deploy anything to Netlify. Netlify is permanently abandoned. The ONLY deploy target is Cloudflare Pages via git push origin main.
- NEVER use wrangler pages deploy
- NEVER use netlify deploy or any netlify CLI command
- Cloudflare Pages auto-deploys medibo.in from the GitHub repo (build/web is committed)

## After every code change:
Run ~/deploy.sh — this builds, commits, and pushes to production (Cloudflare Pages → medibo.in).
There is no local preview step. Every change goes straight to production via deploy.sh.

## Behaviour
- Wait for user instruction
- Do NOT auto-suggest next steps
