# RULES - NEVER BREAK THESE

## Deploy Rules
- NEVER auto-run any command without user asking
- NEVER type anything in terminal without user asking
- NEVER deploy anything to Netlify. Netlify is permanently abandoned. The ONLY deploy target is Cloudflare Pages via git push origin main.
- NEVER use wrangler pages deploy
- NEVER use netlify deploy or any netlify CLI command
- Only deploy via: git push origin main --force
- Cloudflare Pages auto-deploys medibo.in from the GitHub repo (build/web is committed)

## After every code change:
flutter build web --release
git add -A
git commit -m "update"
git push origin main --force

## Behaviour
- Wait for user instruction
- Do NOT auto-suggest next steps
- Do NOT auto-run deploy after finishing a task
