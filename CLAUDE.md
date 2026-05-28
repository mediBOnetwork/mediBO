# mediBO — Claude Code Instructions

## Auto-build and push after every change

After **every** code change you make, always run these commands automatically without being asked:

```bash
flutter build web --release
git add -A
git commit -m "auto update $(date)"
git push origin main --force
```

**Never skip this step.** Always build and push after every single change, no exceptions.

## Project context

- Flutter 3.44 web app — package name `pharma_b2b`, located at `/home/mimbonetwork/mediBO`
- Build command: `flutter build web --release` (CanvasKit is already the default renderer; `--web-renderer canvaskit` flag was removed in Flutter 3.22 and causes a build failure — never use it)
- Remote: `https://github.com/mediBOnetwork/mediBO.git` on branch `main`
- Supabase backend: `qkcuoaqrpnmdnejzahdv.supabase.co`
- Gemini API key in `lib/config/api_keys.dart`

## Architecture notes

- `AppState` (`InheritedNotifier<CartModel>`) wraps the whole app — use `AppState.of(context)` to read cart state
- `CartModel.distinctItems` = unique products; `CartModel.totalUnits` = total pack quantity
- Bottom nav has 4 items: Home, Catalogue, Orders, Bulk (no Cart item — cart opens as a slide-in panel)
- `IndexedStack` keeps all three screen States alive across tab switches — `StorefrontScreen` state/data is preserved
- `_StickyCartBar` and `CartPanel` are each wrapped in `RepaintBoundary`
- Celebration banners fire when subtotal crosses ₹999 (free delivery) and ₹2999 (3% discount)
