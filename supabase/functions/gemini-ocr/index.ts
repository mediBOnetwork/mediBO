import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MODEL = 'gemini-2.5-flash'
const API_URL = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`

// Company-list prompt: identifies logos and returns official registered Indian company names.
const COMPANY_LIST_PROMPT =
  'This image is a pharma distributor company list containing logos. ' +
  'For EACH cell/logo: identify the company from the logo even if only a symbol or short brand name is visible, ' +
  'and return the full official registered Indian company name ' +
  '(e.g. BSV → Bharat Serums and Vaccines Ltd., Zydus Cadila → Zydus Lifesciences Ltd., ' +
  'Unique logo → J.B. Chemicals & Pharmaceuticals Ltd., Sun → Sun Pharmaceutical Industries Ltd.). ' +
  'Return strict JSON array: [{"visible_name":"...","official_name":"...","confidence":"high|medium|low"}]. ' +
  'If the logo cannot be confidently identified, set official_name = visible_name and confidence = low. ' +
  'Never skip a cell.'

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  try {
    const apiKey = Deno.env.get('GEMINI_API_KEY')
    if (!apiKey) throw new Error('GEMINI_API_KEY not set')

    const body = await req.json() as {
      image_base64?: string
      mime_type?: string
      prompt?: string
      mode?: string
    }

    const { image_base64 = '', mime_type = 'image/jpeg', mode } = body
    const prompt = mode === 'company_list' ? COMPANY_LIST_PROMPT : (body.prompt ?? '')

    if (!prompt) {
      return new Response(JSON.stringify({ error: 'prompt or mode required' }), {
        status: 400, headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    const parts: unknown[] = []
    if (image_base64) {
      parts.push({ inline_data: { mime_type, data: image_base64 } })
    }
    parts.push({ text: prompt })

    const payload = {
      contents: [{ parts }],
      generationConfig: {
        thinkingConfig: { thinkingBudget: 1024 },
      },
    }

    const res = await fetch(`${API_URL}?key=${apiKey}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })

    if (!res.ok) {
      const errText = await res.text()
      throw new Error(`Gemini API error ${res.status}: ${errText}`)
    }

    const data = await res.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>
    }
    const text = data.candidates?.[0]?.content?.parts?.[0]?.text ?? ''

    return new Response(JSON.stringify({ text }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
