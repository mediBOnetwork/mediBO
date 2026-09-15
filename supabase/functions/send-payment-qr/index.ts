import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import QRCode from 'https://esm.sh/qrcode@1.5.4';
import { Resvg, initWasm } from 'https://esm.sh/@resvg/resvg-wasm@2.6.2';
import { Image } from 'https://deno.land/x/imagescript@1.2.15/mod.ts';

const NOTIFY_SECRET='medibo_order_notify_2027';
const WA_TOKEN_HARDCODED='EAARb70T6u7sBR775DNCsEMQLBZBxQbZAVXFtOs5ZBZAAp1NezedqnFzeZAOWN4puSZCVXZBmSj5OWDHAb3ko2IwX96ocuK7HUnDcgvh2XqMwGJG1LutM4ayrN2ZCsAIlVdfZCt8Tpzof0QvWlzpIaHPFmG2qGZA6ItJODC9BLe60ZArqG3y4xzVZBjFvc2bXVtF7ZA9GjZAEmrnev4NwaCH23HZBBLN130UfCZC7hgVK2X4jM2q8VuQc7mMZBsnRpSWHoWen1qZCXBiZCRBKm2z2ZB34eqMhtc3dJ8nG06rC3XI8rXWFtSIZD';
const WA_TOKEN=((Deno.env.get('WHATSAPP_TOKEN')??'').trim())||WA_TOKEN_HARDCODED;
const PHONE_ID_RAW=(Deno.env.get('WHATSAPP_PHONE_ID')??'').trim();
const PHONE_ID=/^[0-9]{6,}$/.test(PHONE_ID_RAW)?PHONE_ID_RAW:'1157319300801672';
const SUPABASE_URL=Deno.env.get('SUPABASE_URL');
const SUPABASE_KEY=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const UPI_PA_FALLBACK='8357881873-6@ibl';
const UPI_PN_FALLBACK='OM PRAKASH SAHU';
const MEDIA_BUCKET='whatsapp-media';
const WASM_URL='https://esm.sh/@resvg/resvg-wasm@2.6.2/index_bg.wasm';
const FONT_REG_URL='https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf';
const FONT_BOLD_URL='https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf';
const supabase=createClient(SUPABASE_URL,SUPABASE_KEY);

function inr(n){return Number(n||0).toLocaleString('en-IN',{maximumFractionDigits:2});}
function xmlEsc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}

async function getActiveUpi(){try{const{data}=await supabase.from('payment_upi_accounts').select('pa,pn').eq('is_active',true).limit(1).maybeSingle();const pa=(data?.pa||'').trim();const pn=(data?.pn||'').trim();if(pa&&pa.includes('@')&&pn)return{pa,pn};}catch(_){}return{pa:UPI_PA_FALLBACK,pn:UPI_PN_FALLBACK};}

let wasmReady=false;let fontReg=null;let fontBold=null;
async function ensureAssets(){try{if(!wasmReady){await initWasm(fetch(WASM_URL));wasmReady=true;}if(!fontReg){const r=await fetch(FONT_REG_URL);fontReg=new Uint8Array(await r.arrayBuffer());}if(!fontBold){const r=await fetch(FONT_BOLD_URL);fontBold=new Uint8Array(await r.arrayBuffer());}return!!(wasmReady&&fontReg&&fontBold);}catch(_){return false;}}

async function renderPayQr(amountStr,label,pa,pn,upiStr){
  try{
    if(!(await ensureAssets()))return null;
    const RENDER_W=1100;const W=1100,PAD=46;
    let s='';let y=96;
    s+=`<text x="${W/2}" y="${y}" text-anchor="middle" font-family="Noto Sans" font-size="60" font-weight="700" fill="#000000">mediBO</text>`;y+=62;
    s+=`<text x="${W/2}" y="${y}" text-anchor="middle" font-family="Noto Sans" font-size="46" font-weight="700" fill="#127a3e">${xmlEsc(label)} ₹${xmlEsc(amountStr)}</text>`;y+=44;
    const qr=QRCode.create(upiStr,{errorCorrectionLevel:'M'});const N=qr.modules.size;const data=qr.modules.data;const QR=W-PAD*2,cell=QR/N,qx=PAD,qy=y;
    s+=`<rect x="${qx-14}" y="${qy-14}" width="${QR+28}" height="${QR+28}" rx="18" fill="#ffffff" stroke="#e2e2e2" stroke-width="2"/>`;
    for(let r=0;r<N;r++)for(let c=0;c<N;c++){if(data[r*N+c])s+=`<rect x="${(qx+c*cell).toFixed(2)}" y="${(qy+r*cell).toFixed(2)}" width="${(cell+0.5).toFixed(2)}" height="${(cell+0.5).toFixed(2)}" fill="#000000"/>`;}
    y=qy+QR+72;
    s+=`<text x="${W/2}" y="${y}" text-anchor="middle" font-family="Noto Sans" font-size="48" font-weight="700" fill="#000000">${xmlEsc(pn)}</text>`;y+=52;
    s+=`<text x="${W/2}" y="${y}" text-anchor="middle" font-family="Noto Sans" font-size="36" fill="#666666">${xmlEsc(pa)}</text>`;y+=30;
    const H=Math.round(y+16);
    const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="#ffffff"/>${s}</svg>`;
    const rr=new Resvg(svg,{font:{fontBuffers:[fontReg,fontBold],defaultFontFamily:'Noto Sans'},fitTo:{mode:'width',value:RENDER_W},background:'#ffffff'});
    return rr.render().asPng();
  }catch(_){return null;}
}

async function pngToJpeg(png,quality=90){try{const img=await Image.decode(png);const jpg=await img.encodeJPEG(quality);return{bytes:jpg,mime:'image/jpeg',ext:'jpg'};}catch(_){return{bytes:png,mime:'image/png',ext:'png'};}}

async function sendText(to,body){try{const r=await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/messages`,{method:'POST',headers:{'Authorization':`Bearer ${WA_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({messaging_product:'whatsapp',recipient_type:'individual',to,type:'text',text:{preview_url:false,body}})});const j=await r.json();return{ok:r.ok,id:j?.messages?.[0]?.id??null,err:r.ok?null:j};}catch(e){return{ok:false,id:null,err:String(e)};}}

async function uploadMedia(bytes,mime,fname){try{const fd=new FormData();fd.append('messaging_product','whatsapp');fd.append('type',mime);fd.append('file',new Blob([bytes],{type:mime}),fname);const up=await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/media`,{method:'POST',headers:{'Authorization':`Bearer ${WA_TOKEN}`},body:fd});return(await up.json())?.id??null;}catch(_){return null;}}

async function storeOutbound(to,bytes,mime,ext){try{const path=`whatsapp/wa_out_payqr_${to}_${Date.now()}.${ext}`;const{error}=await supabase.storage.from(MEDIA_BUCKET).upload(path,bytes,{contentType:mime,upsert:false});if(error)return null;return path;}catch(_){return null;}}

function waFail(err){if(!err)return null;if(typeof err==='string')return err;return err?.error?.message||JSON.stringify(err);}

async function logOut(to,caption,sent,filePath,fname,mime){try{const isImg=!!filePath&&sent?.via==='image';const wamid=sent?.id??null;await supabase.from('whatsapp_messages').insert({sender_phone:to,sender_type:'customer',direction:'out',msg_type:isImg?'image':'text',text_body:isImg?null:caption,caption:isImg?caption:null,file_path:filePath,media_bucket:isImg?MEDIA_BUCKET:null,mime_type:isImg?mime:null,file_name:isImg?fname:null,wa_message_id:wamid,routed_to:sent?.ok?'payment_qr_to_customer':'payment_qr_to_customer_error',received_at:new Date().toISOString(),raw_payload:sent?.err?{error:sent.err}:null,wa_status:wamid?'accepted':'failed',wa_status_at:new Date().toISOString(),wa_fail_reason:wamid?null:waFail(sent?.err)});}catch(_){}}

// ── CHANGE #291 — Razorpay dynamic QR ───────────────────────────────────────
// When payment_config.razorpay_qr_enabled is on, the customer gets a QR that
// belongs to THIS payment and confirms itself through the webhook, instead of
// the shared-VPA deeplink QR this file draws (which needs a screenshot and a
// human). razorpay-qr-create owns the decision: it returns {ok:false,
// enabled:false} when the toggle is off, and any failure here simply falls
// through to the manual UPI path below — the fallback is never lost.
async function razorpayQr(orderId,kind){
  if(!orderId)return null;
  try{
    const r=await fetch(`${SUPABASE_URL}/functions/v1/razorpay-qr-create`,{
      method:'POST',
      headers:{'Content-Type':'application/json','Authorization':`Bearer ${SUPABASE_KEY}`,'apikey':SUPABASE_KEY},
      body:JSON.stringify({order_id:orderId,kind}),
    });
    const j=await r.json();
    if(!r.ok||!j?.ok||!j?.image_url)return null;
    return j;
  }catch(_){return null;}
}

// Meta fetches the Razorpay-hosted PNG itself, so there is nothing to render,
// convert or upload. Caption comes from rzp_qr_view().wa_caption, verbatim.
async function sendRazorpayImage(to,view){
  try{
    const r=await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/messages`,{
      method:'POST',
      headers:{'Authorization':`Bearer ${WA_TOKEN}`,'Content-Type':'application/json'},
      body:JSON.stringify({messaging_product:'whatsapp',recipient_type:'individual',to,type:'image',
        image:{link:view.image_url,caption:view.wa_caption}}),
    });
    const j=await r.json();
    return {ok:r.ok,id:j?.messages?.[0]?.id??null,err:r.ok?null:j,via:'razorpay_image'};
  }catch(e){return {ok:false,id:null,err:String(e),via:'razorpay_image'};}
}

// CHANGE #304 — a payment LINK, not a picture.
// A QR image in a WhatsApp thread cannot open the customer's UPI app: they
// would have to scan it with a SECOND device. A Razorpay payment link opens
// PhonePe/GPay straight from the chat, and the SAME webhook confirms it.
// The link is minted (or RESUMED) by razorpay-checkout-create, so a re-send
// never creates a second payable object for one order.
async function razorpayLink(orderId,kind){
  if(!orderId)return null;
  try{
    const r=await fetch(`${SUPABASE_URL}/functions/v1/razorpay-checkout-create`,{
      method:'POST',
      headers:{'Content-Type':'application/json','Authorization':`Bearer ${SUPABASE_KEY}`,'apikey':SUPABASE_KEY},
      body:JSON.stringify({order_id:orderId,kind,mode:'link'}),
    });
    const j=await r.json();
    if(!r.ok||!j?.ok||!j?.pay_url)return null;
    return j;
  }catch(_){return null;}
}

// The intro sentence and the amount row are the BACKEND's words (razorpay_copy
// via _rzp_attempt_view). Nothing is composed here beyond joining them.
async function sendRazorpayLink(to,view){
  const lines=[view.title,view.subtitle,'',view.link_wa_intro,view.pay_url]
    .filter((x)=>typeof x==='string'&&x.length>0);
  const t=await sendText(to,lines.join('\n'));
  return {...t,via:'razorpay_link'};
}

Deno.serve(async(req)=>{
  if(req.method!=='POST')return new Response('Method not allowed',{status:405});
  if((req.headers.get('x-notify-secret')||'')!==NOTIFY_SECRET)return new Response('Forbidden',{status:403});
  let body;try{body=await req.json();}catch{return new Response('bad json',{status:200});}
  const orderId=String(body?.order_id||'');
  const ph10=String(body?.phone||'').replace(/[^0-9]/g,'').slice(-10);
  const amount=Math.round(Number(body?.amount||0));
  const kind=String(body?.kind||'advance').toLowerCase();
  if(ph10.length!==10||!(amount>0))return new Response(JSON.stringify({skipped:'bad_input'}),{status:200,headers:{'Content-Type':'application/json'}});
  // CHANGE #236: an explicit order_no wins, so a caller with no order row (the
  // sample bill) still shows the invoice number the customer would see.
  let pon=String(body?.order_no||'').trim();
  try{if(!pon&&orderId){const{data:o}=await supabase.from('orders').select('order_code').eq('id',orderId).maybeSingle();pon=(o?.order_code||'').trim();}}catch(_){}
  const to='91'+ph10;

  // #291 — the auto-verified path first. Falls through on anything but success.
  // #304 — the payable LINK first: it is the only one of the three that opens
  // the customer's UPI app from the chat. The QR image below stays as the
  // fallback, and the manual UPI card below that as the fallback's fallback.
  const linkView=await razorpayLink(orderId,kind);
  if(linkView){
    const sentLink=await sendRazorpayLink(to,linkView);
    if(sentLink.ok){
      await logOut(to,linkView.pay_url,{...sentLink,via:'text'},null,null,null);
      return new Response(JSON.stringify({ok:true,to,amount:linkView.amount,kind,order_no:pon||null,
        via:'razorpay_link',pay_url:linkView.pay_url,rzp_link_id:linkView.rzp_link_id,
        reused:!!linkView.reused}),
        {status:200,headers:{'Content-Type':'application/json'}});
    }
  }

  const rzpView=await razorpayQr(orderId,kind);
  if(rzpView){
    const sentRzp=await sendRazorpayImage(to,rzpView);
    if(sentRzp.ok){
      await logOut(to,rzpView.wa_caption,{...sentRzp,via:'text'},null,null,null);
      return new Response(JSON.stringify({ok:true,to,amount:rzpView.amount,kind,order_no:pon||null,
        via:'razorpay_image',rzp_qr_id:rzpView.rzp_qr_id,reused:!!rzpView.reused}),
        {status:200,headers:{'Content-Type':'application/json'}});
    }
    // Meta refused the hosted image — send the caption as text with the link
    // rather than dropping the auto-verified QR back to the manual one.
    const t=await sendText(to,`${rzpView.wa_caption}\n\n${rzpView.image_url}`);
    if(t.ok){
      await logOut(to,rzpView.wa_caption,{...t,via:'text'},null,null,null);
      return new Response(JSON.stringify({ok:true,to,amount:rzpView.amount,kind,order_no:pon||null,
        via:'razorpay_text',rzp_qr_id:rzpView.rzp_qr_id}),
        {status:200,headers:{'Content-Type':'application/json'}});
    }
  }

  const {pa,pn}=await getActiveUpi();
  const tn=(kind==='remaining'?'Remaining ':(kind==='advance'?'Advance ':''))+(pon||'mediBO');
  const upi=`upi://pay?pa=${pa}&pn=${encodeURIComponent(pn)}&am=${amount}&cu=INR&tn=${encodeURIComponent(tn)}`;
  const label=kind==='remaining'?'Pay Remaining':(kind==='advance'?'Pay Advance':'Pay');
  const caption=`💳 *Payment — mediBO*\n\n`+(pon?`*Order ID:* ${pon}\n`:``)+`*Amount:* ₹${inr(amount)}\n*UPI ID:* ${pa}\n*Name:* ${pn}\n\nUpar diye QR se ya UPI ID par ₹${inr(amount)} pay karein.`;
  const png=await renderPayQr(inr(amount),label,pa,pn,upi);
  let sent;let storedPath=null;let mime='image/jpeg';let ext='jpg';
  if(png){
    const conv=await pngToJpeg(png,90);const bytes=conv.bytes;mime=conv.mime;ext=conv.ext;
    storedPath=await storeOutbound(to,bytes,mime,ext);
    const fname=`mediBO-pay-${amount}.${ext}`;
    const mediaId=await uploadMedia(bytes,mime,fname);
    if(mediaId){
      try{
        const r=await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/messages`,{method:'POST',headers:{'Authorization':`Bearer ${WA_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({messaging_product:'whatsapp',recipient_type:'individual',to,type:'image',image:{id:mediaId,caption}})});
        const j=await r.json();
        sent={ok:r.ok,id:j?.messages?.[0]?.id??null,err:r.ok?null:j,via:'image'};
      }catch(e){sent={ok:false,id:null,err:String(e),via:'image'};}
    }else{const t=await sendText(to,caption+'\n\nPay: '+upi);sent={...t,via:'text_fallback'};}
  }else{const t=await sendText(to,caption+'\n\nPay: '+upi);sent={...t,via:'text_fallback'};}
  await logOut(to,caption,sent,sent.via==='image'?storedPath:null,`mediBO-pay-${amount}.${ext}`,mime);
  return new Response(JSON.stringify({ok:sent.ok,to,amount,kind,order_no:pon||null,via:sent.via,err:sent.err}),{status:200,headers:{'Content-Type':'application/json'}});
});
