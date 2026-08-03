import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { Resvg, initWasm } from 'https://esm.sh/@resvg/resvg-wasm@2.6.2';
import { Image } from 'https://deno.land/x/imagescript@1.2.15/mod.ts';

const NOTIFY_SECRET='medibo_order_notify_2027';
const WA_TOKEN_HARDCODED='EAARb70T6u7sBR775DNCsEMQLBZBxQbZAVXFtOs5ZBZAAp1NezedqnFzeZAOWN4puSZCVXZBmSj5OWDHAb3ko2IwX96ocuK7HUnDcgvh2XqMwGJG1LutM4ayrN2ZCsAIlVdfZCt8Tpzof0QvWlzpIaHPFmG2qGZA6ItJODC9BLe60ZArqG3y4xzVZBjFvc2bXVtF7ZA9GjZAEmrnev4NwaCH23HZBBLN130UfCZC7hgVK2X4jM2q8VuQc7mMZBsnRpSWHoWen1qZCXBiZCRBKm2z2ZB34eqMhtc3dJ8nG06rC3XI8rXWFtSIZD';
const WA_TOKEN=((Deno.env.get('WHATSAPP_TOKEN')??'').trim())||WA_TOKEN_HARDCODED;
const PHONE_ID_RAW=(Deno.env.get('WHATSAPP_PHONE_ID')??'').trim();
const PHONE_ID=/^[0-9]{6,}$/.test(PHONE_ID_RAW)?PHONE_ID_RAW:'1157319300801672';
const SUPABASE_URL=Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const supabase=createClient(SUPABASE_URL,SUPABASE_KEY);
const MEDIA_BUCKET='whatsapp-media';
const EXPIRE_MINS=10;
const WASM_URL='https://esm.sh/@resvg/resvg-wasm@2.6.2/index_bg.wasm';
const FONT_REG_URL='https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf';
const FONT_BOLD_URL='https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf';

const DEFAULT_TMPL='*Stock inquiry — mediBO*\n\nNamaste {supplier}, aaj ke order ke liye kuch items ka inquiry karna hai, dekh ke bataiye to kya ye item aapke paas available hai?\n\nNeeche diye link par apna response submit karein:\n\n{link}\n\nJaldi reply karein, inquiry {mins} min me expire ho jaayega. Dhanyavaad.';

function firstPhone10(s:string):string{const parts=String(s||'').split(/[,\/;\s]+/);for(const p of parts){const d=p.replace(/[^0-9]/g,'');if(d.length>=10)return d.slice(-10);}return '';}
function xmlEsc(s:string){return String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function safeFileName(s:string):string{return String(s||'inquiry').replace(/[^0-9A-Za-z._-]/g,'').slice(0,80)||'inquiry';}
function wrapText(s:string,sz:number,width:number,maxLines=2):string[]{s=String(s||'').trim();if(!s)return[];const budget=Math.max(1,Math.floor(width/(sz*0.58)));const words=s.split(/\s+/);const lines:string[]=[];let cur='';for(const w of words){const t=cur?cur+' '+w:w;if(t.length<=budget||!cur)cur=t;else{lines.push(cur);cur=w;}if(lines.length===maxLines)break;}if(lines.length<maxLines&&cur)lines.push(cur);if(lines.join(' ')!==s&&lines.length){let last=lines[lines.length-1];while(last.length>0&&(last.length+1)>budget)last=last.slice(0,-1);lines[lines.length-1]=last.replace(/\s+$/,'')+'…';}return lines.slice(0,maxLines);}

let wasmReady=false;let fontReg:Uint8Array|null=null;let fontBold:Uint8Array|null=null;
async function ensureAssets(){try{if(!wasmReady){await initWasm(fetch(WASM_URL));wasmReady=true;}if(!fontReg){const r=await fetch(FONT_REG_URL);fontReg=new Uint8Array(await r.arrayBuffer());}if(!fontBold){const r=await fetch(FONT_BOLD_URL);fontBold=new Uint8Array(await r.arrayBuffer());}return!!(wasmReady&&fontReg&&fontBold);}catch(_){return false;}}
function b64(bytes:Uint8Array):string{let s='';const CH=0x8000;for(let i=0;i<bytes.length;i+=CH){s+=String.fromCharCode.apply(null,Array.from(bytes.subarray(i,i+CH)) as any);}return btoa(s);}

async function fetchImg(url:string):Promise<string|null>{
  if(!url||!/^https?:\/\//i.test(url))return null;
  try{
    const ctl=new AbortController();const t=setTimeout(()=>ctl.abort(),6000);
    const r=await fetch(url,{signal:ctl.signal});clearTimeout(t);
    if(!r.ok)return null;
    const buf=new Uint8Array(await r.arrayBuffer());
    if(!buf.length||buf.length>3_000_000)return null;
    try{const img=await Image.decode(buf);const jpg=await img.encodeJPEG(80);return 'data:image/jpeg;base64,'+b64(jpg);}
    catch(_){const ct=(r.headers.get('content-type')||'image/jpeg').split(';')[0];return `data:${ct};base64,`+b64(buf);}
  }catch(_){return null;}
}

type Row={name:string;pack:string;cat:string;co:string;img:string|null};

async function renderInquiry(rows:Row[],supplier:string,code:string,when:string):Promise<Uint8Array|null>{
  try{
    if(!(await ensureAssets()))return null;
    // Width tuned so the text column fills the canvas — no dead space on the right.
    const W=920,PAD=40;
    const THUMB=200, ROW_GAP=16;
    const TXT_X=PAD+THUMB+26, TXT_W=W-TXT_X-PAD;   // 614px of text column
    const F_NAME=40,F_PACK=29,F_CHIP=27,F_CO=29;
    let s='';let y=0;

    // ---- HEADER (redesigned 23 Jul 2026: green pill + green rule, matching purchase order header) ----
    y=86;
    s+=`<text x="${W/2}" y="${y}" text-anchor="middle" font-family="Noto Sans" font-size="56" font-weight="700" fill="#0f7a3d">mediBO</text>`;
    y+=52;
    {
      const pillFont=29;
      const pillText=`Stock Inquiry • ${supplier}`;
      let pillFontUse=pillFont;
      let pillW=Math.round(pillText.length*pillFontUse*0.58)+72;
      const maxPillW=W-PAD*2;
      if(pillW>maxPillW){
        pillFontUse=Math.max(18, Math.floor(pillFontUse*maxPillW/pillW));
        pillW=Math.round(pillText.length*pillFontUse*0.58)+72;
        if(pillW>maxPillW)pillW=maxPillW;
      }
      const pillH=54;
      const px0=Math.round((W-pillW)/2);
      const pillTop=y-pillFontUse+4;
      s+=`<rect x="${px0}" y="${pillTop}" width="${pillW}" height="${pillH}" rx="${pillH/2}" fill="#f1f8f3"/>`;
      s+=`<text x="${W/2}" y="${pillTop+pillH/2+pillFontUse*0.34}" text-anchor="middle" font-family="Noto Sans" font-size="${pillFontUse}" font-weight="700" fill="#0f7a3d">${xmlEsc(pillText)}</text>`;
      y=pillTop+pillH+28;
    }
    s+=`<text x="${W/2}" y="${y}" text-anchor="middle" font-family="Noto Sans" font-size="25" fill="#888888">${xmlEsc(code)} • ${xmlEsc(when)} • ${rows.length} item${rows.length===1?'':'s'}</text>`;
    y+=24;
    s+=`<line x1="${PAD}" y1="${y}" x2="${W-PAD}" y2="${y}" stroke="#0f7a3d" stroke-width="3"/>`;
    y+=ROW_GAP;

    for(let i=0;i<rows.length;i++){
      const r=rows[i];
      const top=y;
      s+=`<rect x="${PAD}" y="${top}" width="${THUMB}" height="${THUMB}" rx="14" fill="#ffffff" stroke="#e3e3e3" stroke-width="2"/>`;
      if(r.img){
        s+=`<image x="${PAD+8}" y="${top+8}" width="${THUMB-16}" height="${THUMB-16}" preserveAspectRatio="xMidYMid meet" href="${r.img}"/>`;
      }else{
        s+=`<text x="${PAD+THUMB/2}" y="${top+THUMB/2+10}" text-anchor="middle" font-family="Noto Sans" font-size="25" fill="#c2c2c2">No image</text>`;
      }

      let ty=top+46;
      for(const ln of wrapText(r.name,F_NAME,TXT_W,2)){
        s+=`<text x="${TXT_X}" y="${ty}" font-family="Noto Sans" font-size="${F_NAME}" font-weight="700" fill="#111111">${xmlEsc(ln)}</text>`;
        ty+=46;
      }
      if(r.pack){
        for(const ln of wrapText(r.pack,F_PACK,TXT_W,1)){
          s+=`<text x="${TXT_X}" y="${ty}" font-family="Noto Sans" font-size="${F_PACK}" fill="#0f7a3d">${xmlEsc(ln)}</text>`;
          ty+=40;
        }
      }
      if(r.cat){
        const chW=Math.min(TXT_W, Math.round(r.cat.length*F_CHIP*0.62)+40);
        s+=`<rect x="${TXT_X}" y="${ty-27}" width="${chW}" height="42" rx="21" fill="#eef4ff"/>`;
        s+=`<text x="${TXT_X+20}" y="${ty+2}" font-family="Noto Sans" font-size="${F_CHIP}" font-weight="700" fill="#3b5bdb">${xmlEsc(r.cat)}</text>`;
        ty+=50;
      }
      if(r.co){
        for(const ln of wrapText(r.co,F_CO,TXT_W,1)){
          s+=`<text x="${TXT_X}" y="${ty}" font-family="Noto Sans" font-size="${F_CO}" fill="#666666">${xmlEsc(ln)}</text>`;
          ty+=36;
        }
      }
      const rowH=Math.max(THUMB, ty-top-8);
      y=top+rowH+ROW_GAP;
      if(i<rows.length-1){s+=`<line x1="${PAD}" y1="${y-ROW_GAP/2}" x2="${W-PAD}" y2="${y-ROW_GAP/2}" stroke="#ededed" stroke-width="2"/>`;}
    }

    s+=`<line x1="${PAD}" y1="${y}" x2="${W-PAD}" y2="${y}" stroke="#111111" stroke-width="3"/>`;
    y+=40;

    // ---- FOOTER (redesigned 23 Jul 2026: "Response link par jaakar submit karein" as a green badge)
    {
      const badgeFont=27;
      const badgeText='Response link par jaakar submit karein';
      let badgeW=Math.round(badgeText.length*badgeFont*0.56)+64;
      const maxBadgeW=W-PAD*2;
      let badgeFontUse=badgeFont;
      if(badgeW>maxBadgeW){
        badgeFontUse=Math.max(16, Math.floor(badgeFontUse*maxBadgeW/badgeW));
        badgeW=Math.round(badgeText.length*badgeFontUse*0.56)+64;
        if(badgeW>maxBadgeW)badgeW=maxBadgeW;
      }
      const badgeH=54;
      const bx0=Math.round((W-badgeW)/2);
      const bTop=y;
      s+=`<rect x="${bx0}" y="${bTop}" width="${badgeW}" height="${badgeH}" rx="${badgeH/2}" fill="#f1f8f3"/>`;
      s+=`<text x="${W/2}" y="${bTop+badgeH/2+badgeFontUse*0.34}" text-anchor="middle" font-family="Noto Sans" font-size="${badgeFontUse}" font-weight="700" fill="#0f7a3d">${xmlEsc(badgeText)}</text>`;
      y=bTop+badgeH;
    }
    y+=22;

    const H=Math.round(y+18);
    const svg=`<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="#ffffff"/>${s}</svg>`;
    const rr=new Resvg(svg,{font:{fontBuffers:[fontReg!,fontBold!],defaultFontFamily:'Noto Sans'},fitTo:{mode:'width',value:W},background:'#ffffff'});
    return rr.render().asPng();
  }catch(_){return null;}
}

async function pngToJpeg(png:Uint8Array,q=88){try{const img=await Image.decode(png);return{bytes:await img.encodeJPEG(q),mime:'image/jpeg',ext:'jpg'};}catch(_){return{bytes:png,mime:'image/png',ext:'png'};}}
async function sendText(to:string,body:string){try{const r=await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/messages`,{method:'POST',headers:{'Authorization':`Bearer ${WA_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({messaging_product:'whatsapp',recipient_type:'individual',to,type:'text',text:{preview_url:true,body}})});const j=await r.json();return{ok:r.ok,id:j?.messages?.[0]?.id??null,err:r.ok?null:j};}catch(e){return{ok:false,id:null,err:String(e)};}}
async function uploadMedia(bytes:Uint8Array,mime:string,fname:string):Promise<string|null>{try{const fd=new FormData();fd.append('messaging_product','whatsapp');fd.append('type',mime);fd.append('file',new Blob([bytes],{type:mime}),fname);const up=await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/media`,{method:'POST',headers:{'Authorization':`Bearer ${WA_TOKEN}`},body:fd});return(await up.json())?.id??null;}catch(_){return null;}}
async function storeOutbound(to:string,bytes:Uint8Array,mime:string,ext:string):Promise<string|null>{try{const path=`whatsapp/wa_out_inquiry_${to}_${Date.now()}.${ext}`;const{error}=await supabase.storage.from(MEDIA_BUCKET).upload(path,bytes,{contentType:mime,upsert:false});if(error)return null;return path;}catch(_){return null;}}
function waFailReason(sent:any):string|null{if(!sent?.err)return null;if(typeof sent.err==='string')return sent.err;return sent.err?.error?.message||JSON.stringify(sent.err);}
async function logOutbound(to:string,body:string,sent:any,routed:string,filePath:string|null,fname:string,mime:string){try{const isDoc=!!filePath&&(sent?.via==='document');const wamid=sent?.id??null;await supabase.from('whatsapp_messages').insert({sender_phone:to,sender_type:'supplier',direction:'out',msg_type:isDoc?'document':'text',text_body:isDoc?null:body,caption:isDoc?body:null,file_path:filePath,media_bucket:isDoc?MEDIA_BUCKET:null,mime_type:isDoc?mime:null,file_name:isDoc?fname:null,wa_message_id:wamid,routed_to:sent?.ok?routed:routed+'_error',received_at:new Date().toISOString(),raw_payload:sent?.err?{error:sent.err}:null,wa_status:wamid?'accepted':'failed',wa_status_at:new Date().toISOString(),wa_fail_reason:wamid?null:waFailReason(sent)});}catch(_){}}
function istNow(){const d=new Date(Date.now()+330*60000);const dd=String(d.getUTCDate()).padStart(2,'0');const mm=String(d.getUTCMonth()+1).padStart(2,'0');const yy=String(d.getUTCFullYear()).slice(-2);let h=d.getUTCHours();const mi=String(d.getUTCMinutes()).padStart(2,'0');const ap=h>=12?'PM':'AM';h=h%12;if(h===0)h=12;return `${dd}/${mm}/${yy}, ${h}:${mi} ${ap}`;}

Deno.serve(async(req)=>{
  if(req.method!=='POST')return new Response('Method not allowed',{status:405});
  if((req.headers.get('x-notify-secret')||'')!==NOTIFY_SECRET)return new Response('Forbidden',{status:403});
  let body:any;try{body=await req.json();}catch{return new Response('bad json',{status:200});}
  const supplier=String(body?.supplier_name||'').trim();
  if(!supplier)return new Response(JSON.stringify({skipped:'no_supplier'}),{status:200});

  // MANUAL SHARE: optional explicit target number chosen by the admin in the share popup.
  // When absent, behaviour is exactly as before (first number on the supplier profile).
  const wantPhone=firstPhone10(String(body?.to_phone||''));

  const{data:sp}=await supabase.from('supplier_profiles').select('whatsapp_no,contact_no,phone').eq('supplier_name',supplier).order('SPN',{ascending:false}).limit(1).maybeSingle();
  if(!sp)return new Response(JSON.stringify({skipped:'no_supplier_profile'}),{status:200});
  const ph=wantPhone||firstPhone10(sp.whatsapp_no||'')||firstPhone10(sp.contact_no||'')||firstPhone10(sp.phone||'');
  if(ph.length!==10)return new Response(JSON.stringify({skipped:'no_phone'}),{status:200});
  const to='91'+ph;

  const g=await supabase.rpc('notif_should_send',{p_audience:'supplier',p_action_key:'supplier_inquiry_sent',p_phone:ph});
  if(g.data===false)return new Response(JSON.stringify({skipped:'notif_disabled'}),{status:200});

  const{data:inq}=await supabase.from('inquiry').select('inquiry_code').eq('current_supplier',supplier).not('inquiry_code','is',null).order('id',{ascending:true}).limit(1).maybeSingle();
  const code=inq?.inquiry_code?String(inq.inquiry_code).trim():'';
  if(!code)return new Response(JSON.stringify({skipped:'no_inquiry_code'}),{status:200});
  // Secret-bearing link (5-char code appended). link_for_code also ensures the form row exists.
  let link='https://medibo.in/'+code;
  try{const{data:lf}=await supabase.rpc('link_for_code',{p_code:code});if(typeof lf==='string'&&lf.startsWith('https://'))link=lf;}catch(_){}

  // ── CHANGE #639 PART B3 — ITEM ORDER IS POSTGRES'S ANSWER ─────────────────
  //
  // This file used to fetch the inquiry rows, fetch MEDICINE metadata into a
  // local map, and then run its OWN list.sort() (company -> class -> name).
  // That was a second opinion about item order living outside the database:
  // the picture and the web form each held an answer to the same question, and
  // the day the canonical order changed they would have disagreed.
  //
  // inquiry_wa_image_rows() now returns the rows already ordered and already
  // formatted (pack cleaned exactly as cleanPack() used to clean it). This
  // renderer draws them in the order received and sorts nothing.
  const MAX_IMG=40;
  const{data:rowData}=await supabase.rpc('inquiry_wa_image_rows',{p_supplier:supplier,p_code:code});
  const baseRows=(Array.isArray(rowData)?rowData:[]).map((r:any)=>({
    name:String(r?.name??'').trim(),
    pack:String(r?.pack??'').trim(),
    cat:String(r?.cat??'').trim(),
    co:String(r?.co??'').trim(),
    imgUrl:String(r?.img??'').trim(),
  }));
  const fetched=await Promise.all(baseRows.slice(0,MAX_IMG).map(r=>fetchImg(r.imgUrl)));
  const rows:Row[]=baseRows.map((r,i)=>({name:r.name,pack:r.pack,cat:r.cat,co:r.co,img:i<MAX_IMG?(fetched[i]??null):null}));

  let tmpl='';try{const{data:t}=await supabase.from('app_settings').select('value').eq('key','inquiry_wa_message').maybeSingle();if(t&&typeof t.value==='string')tmpl=t.value;}catch(_){}
  if(!tmpl||!tmpl.trim())tmpl=DEFAULT_TMPL;
  const caption=tmpl.replace(/\{supplier\}/g,supplier).replace(/\{link\}/g,link)
                    .replace(/\{mins\}/g,String(EXPIRE_MINS)).replace(/\{count\}/g,String(rows.length));

  let sent:any; let storedPath:string|null=null; let mime='image/jpeg'; let ext='jpg';
  const fileBase=`mediBO-${safeFileName(code)}`;
  const png=rows.length?await renderInquiry(rows,supplier,code,istNow()):null;

  if(png){
    const conv=await pngToJpeg(png,88);mime=conv.mime;ext=conv.ext;
    storedPath=await storeOutbound(to,conv.bytes,mime,ext);
    const fname=`${fileBase}.${ext}`;
    const mediaId=await uploadMedia(conv.bytes,mime,fname);
    if(mediaId){
      try{
        const r=await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/messages`,{method:'POST',headers:{'Authorization':`Bearer ${WA_TOKEN}`,'Content-Type':'application/json'},body:JSON.stringify({messaging_product:'whatsapp',recipient_type:'individual',to,type:'document',document:{id:mediaId,caption,filename:fname}})});
        const j=await r.json();
        sent={ok:r.ok,id:j?.messages?.[0]?.id??null,err:r.ok?null:j,via:'document'};
      }catch(e){sent={ok:false,id:null,err:String(e),via:'document'};}
    }else{const t=await sendText(to,caption);sent={...t,via:'text_fallback'};}
  }else{
    const t=await sendText(to,caption);sent={...t,via:'text_fallback'};}

  await logOutbound(to,caption,sent,'inquiry_notify',sent.via==='document'?storedPath:null,`${fileBase}.${ext}`,mime);
  return new Response(JSON.stringify({ok:sent.ok,to,supplier,code,link,items:rows.length,via:sent.via,manual:!!wantPhone,err:sent.err}),{status:200,headers:{'Content-Type':'application/json'}});
});
