{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    // Load CanvasKit from Google's CDN instead of our bundle.
    // CDN URLs are versioned (immutable), so the browser caches them indefinitely
    // after the first load — repeat visits skip the 6.9 MB WASM download entirely.
    useLocalCanvasKit: false,
  },
  serviceWorkerSettings: null,
  onEntrypointLoaded: async (engineInitializer) => {
    const appRunner = await engineInitializer.initializeEngine({});
    // Fade out the loading screen right before the Flutter app paints.
    const loader = document.getElementById('flutter-loading');
    if (loader) {
      loader.style.opacity = '0';
      loader.style.transition = 'opacity 0.25s ease';
      setTimeout(() => { if (loader && loader.parentNode) loader.parentNode.removeChild(loader); }, 300);
    }
    await appRunner.runApp();
  },
});
