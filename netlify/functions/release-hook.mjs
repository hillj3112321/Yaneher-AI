/** Optional GitHub release webhook -> unpublished release draft in Supabase.
 * Set GITHUB_WEBHOOK_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY in Netlify,
 * configure GitHub webhook https://SITE.netlify.app/api/release-hook
 * Content type application/json, event: Releases. NEVER expose service role key publicly.
 */
import {createHmac,timingSafeEqual} from 'node:crypto';
const json=(payload,status=200)=>new Response(JSON.stringify(payload),{status,headers:{'content-type':'application/json','cache-control':'no-store'}});
export default async function handler(request){
 if(request.method!=='POST')return json({error:'POST required'},405);
 const secret=process.env.GITHUB_WEBHOOK_SECRET;
 const url=(process.env.SUPABASE_URL||'').replace(/\/$/,'');
 const key=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!secret||!url||!key)return json({error:'Webhook not configured'},503);
 const body=await request.text();if(body.length>500000)return json({error:'Too large'},413);
 const signature=request.headers.get('x-hub-signature-256')||'';
 const expected='sha256='+createHmac('sha256',secret).update(body).digest('hex');
 const a=Buffer.from(signature),b=Buffer.from(expected);
 if(a.length!==b.length||!timingSafeEqual(a,b))return json({error:'Invalid signature'},401);
 if(request.headers.get('x-github-event')!=='release')return json({ok:true,ignored:'event'});
 let event;try{event=JSON.parse(body)}catch{return json({error:'Invalid JSON'},400)}
 if(event.action!=='published'||!event.release)return json({ok:true,ignored:'action'});
 const title=String(event.release.name||event.release.tag_name||'Новый выпуск').slice(0,140),
  notes=String(event.release.body||'').slice(0,12000),tag=String(event.release.tag_name||'').slice(0,120);
 const headers={apikey:key,Authorization:'Bearer '+key,'content-type':'application/json'};
 try{
  const existing=await fetch(url+'/rest/v1/releases?select=id&source_tag=eq.'+encodeURIComponent(tag),{headers});
  if(!existing.ok)return json({error:'Supabase lookup failed'},502);
  if((await existing.json()).length)return json({ok:true,already_exists:true});
  const latest=await fetch(url+'/rest/v1/releases?select=version&order=version.desc&limit=1',{headers});
  if(!latest.ok)return json({error:'Supabase lookup failed'},502);
  const data=await latest.json();const next=Number(data[0]?.version||0)+1;
  const add=await fetch(url+'/rest/v1/releases',{method:'POST',headers:{...headers,Prefer:'return=minimal'},body:JSON.stringify({version:next,title,description:'Автоматический черновик из GitHub. Администратор должен проверить изменения.',changes:notes,source_tag:tag,is_published:false})});
  if(!add.ok)return json({error:'Could not insert release draft'},502);
  return json({ok:true,draft_version:next});
 }catch{return json({error:'Release hook unavailable'},502)}
}
export const config={path:'/api/release-hook'};
