import "jsr:@supabase/functions-js/edge-runtime.d.ts";

Deno.serve(async (req: Request) => {
  const token    = Deno.env.get('WHATSAPP_TOKEN');
  const phoneId  = Deno.env.get('WHATSAPP_PHONE_ID');
  const template = Deno.env.get('WHATSAPP_TEMPLATE');

  if (!token || !phoneId || !template) {
    return new Response(JSON.stringify({ error: 'meta_not_configured' }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200,
    });
  }

  let body: { suppliers?: Array<{ name: string; phone: string | null; link: string }> };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'invalid_body' }), {
      headers: { 'Content-Type': 'application/json' },
      status: 400,
    });
  }

  const suppliers = body.suppliers ?? [];
  const results: Array<{ name: string; sent: boolean; error?: string }> = [];

  for (const sup of suppliers) {
    if (!sup.phone) {
      results.push({ name: sup.name, sent: false, error: 'no_phone' });
      continue;
    }
    try {
      const res = await fetch(
        `https://graph.facebook.com/v19.0/${phoneId}/messages`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({
            messaging_product: 'whatsapp',
            to: sup.phone,
            type: 'template',
            template: {
              name: template,
              language: { code: 'en' },
              components: [{
                type: 'body',
                parameters: [{ type: 'text', text: sup.link }],
              }],
            },
          }),
        }
      );
      const data = await res.json();
      if (res.ok) {
        results.push({ name: sup.name, sent: true });
      } else {
        results.push({ name: sup.name, sent: false, error: JSON.stringify(data) });
      }
    } catch (e) {
      results.push({ name: sup.name, sent: false, error: String(e) });
    }
  }

  return new Response(JSON.stringify({ results }), {
    headers: { 'Content-Type': 'application/json' },
    status: 200,
  });
});
