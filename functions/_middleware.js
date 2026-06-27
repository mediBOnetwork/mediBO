// CHANGE #239: Intercept flutter_service_worker.js — return 404 so no browser
// can ever register or update a Flutter SW. CF Pages Functions take priority
// over static assets and _redirects rules, so this override works even if the
// old SW file is still present in CF's edge cache from a prior deployment.
export async function onRequest(context) {
  const url = new URL(context.request.url);
  if (url.pathname === '/flutter_service_worker.js') {
    return new Response('Not found', { status: 404, headers: { 'Cache-Control': 'no-store' } });
  }
  return context.next();
}
