# MANDATORY RULE - NEVER SKIP

After EVERY change to ANY file, you MUST run these commands:

```bash
cd ~/mediBO
flutter build web --release
git add -A
git commit -m "auto deploy $(date +%H:%M)"
git push origin main --force
echo "✅ DEPLOYED TO MEDIBO.IN"
```

Do not stop until `git push` shows success. No exceptions.

## Important build note

Use `flutter build web --release` only — **never** add `--web-renderer canvaskit` (that flag was removed in Flutter 3.22 and causes an immediate build failure).

## Project context

- Flutter 3.44 web app — package name `pharma_b2b`, at `/home/mimbonetwork/mediBO`
- Remote: `https://github.com/mediBOnetwork/mediBO.git` branch `main`
- Supabase: `qkcuoaqrpnmdnejzahdv.supabase.co`
- Gemini key: `lib/config/api_keys.dart`

## Architecture

- `AppState` (`InheritedNotifier<CartModel>`) — use `AppState.of(context)` for cart state
- `CartModel.distinctItems` = unique products; `totalUnits` = total pack qty
- Bottom nav: 4 items — Home, Catalogue, Orders, Bulk (Cart opens as slide-in panel)
- `IndexedStack` keeps all three screen States alive across tab switches
- `RepaintBoundary` on `_StickyCartBar`, `CartPanel`, and `Shimmer`
- Celebration banners fire at ₹999 (free delivery) and ₹2999 (3% discount)
