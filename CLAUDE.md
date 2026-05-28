# RULES - NEVER BREAK THESE

## Deploy Rules
- NEVER auto-run any command without user asking
- NEVER type anything in terminal without user asking
- NEVER use wrangler pages deploy
- NEVER use netlify deploy
- Only deploy via: git push origin main --force

## After every code change:
flutter build web --release
git add -A
git commit -m "update"
git push origin main --force

## Behaviour
- Wait for user instruction
- Do NOT auto-suggest next steps
- Do NOT auto-run deploy after finishing a task
