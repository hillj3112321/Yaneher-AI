/* Optional authenticated multi-user tools via Supabase + RLS. No fabricated data. */
const v10Config=window.YANE_CONFIG||{};let v10SB=null,v10User=null,v10Profile=null,v10Settings=null,v10Realtime=null,v10Admin=false;
let v10BackendReady=false,v10MessageHistory=[];
function v10ValidURL(x){try{const u=new URL(x);return u.protocol==='https:'?u.href:null}catch(e){return null}}
function v10ExternalLink(url,caption){const safe=v10ValidURL(url);return safe?`<a href="${esc(safe)}" target="_blank" rel="noopener noreferrer">${esc(caption)}</a>`:''}
function v10LoadLibrary(){return new Promise((resolve,reject)=>{if(window.supabase?.createClient)return resolve();const s=document.createElement('script');s.src='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js';s.crossOrigin='anonymous';s.onload=resolve;s.onerror=()=>reject(new Error('Не удалось загрузить библиотеку Supabase'));document.head.appendChild(s)})}
async function v10InitCommunity(){
 if(!v10Config.supabaseUrl||!v10Config.supabaseAnonKey){$('#v10-auth-state').textContent='Нужен Supabase';return}
 try{
 await v10LoadLibrary();v10SB=window.supabase.createClient(v10Config.supabaseUrl,v10Config.supabaseAnonKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
 const {data:{user}}=await v10SB.auth.getUser();v10User=user;await v10HandleUser();
 await Promise.all([v10LoadSettings(),v10LoadMembers(),v10LoadFeatured(),v10LoadChat()]);
 v10SB.auth.onAuthStateChange((event,session)=>{v10User=session?.user||null;setTimeout(()=>v10HandleUser(),0)});
 v10Realtime=v10SB.channel('public-chat-v10').on('postgres_changes',{event:'*',schema:'public',table:'chat_messages'},()=>v10LoadChat()).on('postgres_changes',{event:'*',schema:'public',table:'featured_videos'},()=>v10LoadFeatured()).subscribe();
 $('#v10-chat-status').textContent='ONLINE';$('#v10-backend-state').textContent='● Сообщество подключено';$('#v10-backend-state').classList.add('ready');
 }catch(e){$('#v10-auth-state').textContent='Ошибка подключения';$('#v10-login-message').textContent=e.message;console.warn('Community init:',e)}
}
async function v10HandleUser(){
 v10Profile=null;v10Admin=false;
 if(v10User&&v10SB){const {data}=await v10SB.from('profiles').select('id,display_name,avatar_url,role').eq('id',v10User.id).maybeSingle();v10Profile=data;v10Admin=data?.role==='admin'}
 $('#v10-auth-state').textContent=v10User?(v10Profile?.display_name||'Авторизован'):'Гость';$('#v10-signout').hidden=!v10User;$('#v10-signin').disabled=!!v10User;
 $('#v10-admin-locked').hidden=v10Admin;$('#v10-admin-editor').hidden=!v10Admin;
 if(v10Admin)await v10AdminRefresh();
}
async function v10LoadSettings(){if(!v10SB)return;const {data,error}=await v10SB.from('site_settings').select('*').eq('id','main').maybeSingle();if(error){console.warn(error);return}v10Settings=data||null;
 if(data){$('#v10-official-rules').textContent=data.official_rules||'Официальный подтверждённый текст пока не опубликован.';$('#v10-extra-rules').textContent=data.extra_rules||'Дополнительные правила пока не опубликованы.';
 if(data.banner_path){const {data:pub}=v10SB.storage.from('banners').getPublicUrl(data.banner_path);if(pub?.publicUrl){$('#v10-rules-banner').hidden=false;$('#v10-rules-banner-img').src=pub.publicUrl;$('#v10-banner').hidden=false;$('#v10-banner-image').innerHTML=`<img src="${esc(pub.publicUrl)}" alt="Баннер проекта" style="max-width:100%;max-height:250px">`}}}
}
async function v10LoadMembers(){if(!v10SB)return;const {data,error}=await v10SB.from('members').select('id,nickname,username,avatar_url,status,created_at').order('created_at',{ascending:true}).limit(250);
 if(error){$('#v10-cutter-list').innerHTML='<div class="v10-empty">Не удалось получить список: '+esc(error.message)+'</div>';return}
 const n=data?.length||0,cap=v10Settings?.capacity||10;$('#v10-slots').textContent=n+' / '+cap;$('#v10-cutters-status').textContent=n<cap?'Набор открыт':'Мест нет';
 $('#v10-cutter-list').innerHTML=n?data.map(m=>{let u=v10ValidURL(m.avatar_url),pic=u?`<img class="v10-avatar" src="${esc(u)}" alt="Аватар ${esc(m.nickname)}" loading="lazy" referrerpolicy="no-referrer">`:'<div class="v10-avatar v10-avatar-fallback">Y</div>';let st=m.status==='active'?'Активен':m.status==='pause'?'Пауза':'Новичок';return`<div class="card"><div class="v10-member">${pic}<div><strong>${esc(m.nickname)}</strong><small>@${esc(m.username||'')}</small><span class="pill">${st}</span></div></div></div>`}).join(''):'<div class="v10-empty">Участники пока не добавлены. Фиктивные профили не показываются.</div>';
 if(v10Admin)$('#v10-admin-members').innerHTML=(data||[]).map(m=>`<div class="v10-admin-row"><span>${esc(m.nickname)} @${esc(m.username)}</span><button class="btn sm danger" data-removemember="${esc(m.id)}">Удалить</button></div>`).join('')
}
function v10Player(url){const safe=v10ValidURL(url);if(!safe)return'';try{const u=new URL(safe);const host=u.hostname.replace(/^www\./,'');let id=null;
 if(host==='youtu.be')id=u.pathname.slice(1).split('/')[0];else if(['youtube.com','m.youtube.com'].includes(host))id=u.searchParams.get('v')||u.pathname.match(/^\/(?:shorts|embed)\/([^/]+)/)?.[1];
 if(id&&/^[A-Za-z0-9_-]{11}$/.test(id))return`<div class="v10-video-preview"><iframe loading="lazy" src="https://www.youtube-nocookie.com/embed/${id}" title="Просмотр видео" allow="encrypted-media; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></div>`;
 if(/\.mp4(?:$|\?)/i.test(u.pathname))return`<div class="v10-video-preview"><video controls preload="metadata" playsinline src="${esc(safe)}"></video></div>`;
 }catch(e){}return'<div class="v10-video-preview"><span class="v10-hint">Предпросмотр доступен по ссылке на источник</span></div>'}
async function v10LoadFeatured(){if(!v10SB)return;const {data,error}=await v10SB.from('featured_videos').select('*').order('created_at',{ascending:false}).limit(30);
 if(error){$('#v10-best-list').innerHTML='<div class="v10-empty">Ошибка загрузки подтверждённых видео: '+esc(error.message)+'</div>';return}
 $('#v10-best-count').textContent=(data?.length||0)+' видео';$('#v10-best-list').innerHTML=data?.length?data.map(v=>`<div class="card">${v10Player(v.source_url)}<h3>${esc(v.title)}</h3><p>Автор: ${esc(v.author)}</p><p>${esc(v.description||'')}</p><div class="actions">${v10ExternalLink(v.source_url,'Источник ↗')}<button class="btn sm" data-discussvideo="${esc(v.id)}">С ЯнеИИ ✦</button>${v.allow_download&&/\.mp4(?:$|\?)/i.test(v.source_url)?`<a class="btn sm" href="${esc(v10ValidURL(v.source_url))}" download>↓ Скачать</a>`:''}</div></div>`).join(''):'<div class="v10-empty">Подборка пока не опубликована. Добавить ролики с реальными ссылками может только администратор.</div>';
 root._v10Featured=data||[];
 if(v10Admin)$('#v10-admin-videos').innerHTML=(data||[]).map(v=>`<div class="v10-admin-row"><span>${esc(v.title)}</span><button class="btn sm danger" data-removevideo="${esc(v.id)}">Удалить</button></div>`).join('')
}
async function v10LoadChat(){if(!v10SB)return;const {data,error}=await v10SB.from('chat_messages').select('id,author_id,body,created_at,profiles(display_name,avatar_url)').eq('removed',false).order('created_at',{ascending:false}).limit(80);
 if(error){$('#v10-community-messages').innerHTML='<div class="v10-empty">Чат не загрузился: '+esc(error.message)+'</div>';return}
 const rows=(data||[]).reverse();$('#v10-community-messages').innerHTML=rows.length?rows.map(v=>{const p=Array.isArray(v.profiles)?v.profiles[0]:v.profiles;const time=new Date(v.created_at).toLocaleString();return`<div class="v10-chatmsg"><header><b>${esc(p?.display_name||'Участник')}</b><span>${esc(time)} <button type="button" class="btn sm" data-report="${esc(v.id)}" title="Пожаловаться">⚑</button></span></header><p>${esc(v.body)}</p></div>`}).join(''):'<div class="v10-empty">Пока сообщений нет. Начни обсуждение нарезок!</div>';
 $('#v10-community-messages').scrollTop=$('#v10-community-messages').scrollHeight;
}
async function v10AdminRefresh(){if(!v10Admin||!v10SB)return;$('#v10-admin-capacity').value=v10Settings?.capacity||10;$('#v10-admin-official').value=v10Settings?.official_rules||'';$('#v10-admin-extra').value=v10Settings?.extra_rules||'';await Promise.all([v10LoadReports(),v10LoadMembers(),v10LoadFeatured()])}
async function v10LoadReports(){if(!v10Admin)return;const {data,error}=await v10SB.from('chat_reports').select('id,message_id,reason,created_at').eq('resolved',false).order('created_at',{ascending:false}).limit(30);
 $('#v10-reports-list').innerHTML=error?'Ошибка: '+esc(error.message):data?.length?data.map(r=>`<div class="v10-admin-row"><span>Сообщение: ${esc(r.message_id)} · ${esc(r.reason)}</span><button class="btn sm" data-resolve="${esc(r.id)}">Закрыть жалобу</button><button class="btn sm danger" data-hidechat="${esc(r.message_id)}">Удалить сообщение</button></div>`).join(''):'Открытых жалоб нет.'
}
async function v10AdminAction(kind){if(!v10SB||!v10Admin)return toast('Требуется администратор');let error;
 try{if(kind==='settings'){
 const capacity=Number($('#v10-admin-capacity').value);if(!Number.isInteger(capacity)||capacity<1||capacity>1000)throw Error('Укажи количество мест от 1 до 1000.');
 ({error}=await v10SB.from('site_settings').upsert({id:'main',capacity,official_rules:$('#v10-admin-official').value,extra_rules:$('#v10-admin-extra').value}));if(!error)await v10LoadSettings();
 }else if(kind==='member'){
 const nickname=$('#v10-member-name').value.trim(),username=$('#v10-member-handle').value.trim().replace(/^@/,'');if(!nickname||!username)throw Error('Нужен ник и username.');const avatar=$('#v10-member-avatar').value.trim();if(avatar&&!v10ValidURL(avatar))throw Error('Аватар: только HTTPS URL');
 ({error}=await v10SB.from('members').insert({nickname,username,avatar_url:avatar||null,status:$('#v10-member-status').value}));if(!error)await v10LoadMembers();
 }else if(kind==='video'){
 const title=$('#v10-video-title').value.trim(),author=$('#v10-video-author').value.trim(),url=v10ValidURL($('#v10-video-url').value);if(!title||!author||!url)throw Error('Укажи название, автора и HTTPS-ссылку.');
 ({error}=await v10SB.from('featured_videos').insert({title,author,source_url:url,description:$('#v10-video-note').value.slice(0,500),allow_download:$('#v10-video-download').value==='true'}));if(!error)await v10LoadFeatured();
 }else if(kind==='banner'){
 const file=$('#v10-banner-file').files[0];if(!file||!['image/jpeg','image/png'].includes(file.type)||file.size>5e6)throw Error('Выбери JPG/PNG до 5 МБ.');
 const path='project-banner.'+(file.type==='image/png'?'png':'jpg');const r=await v10SB.storage.from('banners').upload(path,file,{upsert:true,contentType:file.type});if(r.error)throw r.error;
 const s=await v10SB.from('site_settings').upsert({id:'main',banner_path:path});if(s.error)throw s.error;await v10LoadSettings();
 }
 if(error)throw error;toast('Сохранено ✓')
 }catch(e){toast('Ошибка: '+e.message)}
}
async function v10SignIn(){if(!v10SB)return toast('Для входа нужен Supabase');const email=$('#v10-email').value.trim();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))return toast('Введи email');const {error}=await v10SB.auth.signInWithOtp({email,options:{emailRedirectTo:window.location.origin+window.location.pathname}});$('#v10-login-message').textContent=error?'Ошибка: '+error.message:'Проверь письмо со ссылкой для входа.'}
async function v10Post(){if(!v10SB)return toast('Нужна база данных');if(!v10User)return toast('Сначала войди по email');const body=$('#v10-chat-message').value.trim();if(!body||body.length>1000)return toast('Сообщение от 1 до 1000 символов');const {error}=await v10SB.from('chat_messages').insert({author_id:v10User.id,body});if(error){toast('Ошибка: '+error.message);return}$('#v10-chat-message').value='';await v10LoadChat()}
async function v10DownloadBanner(){const path=v10Settings?.banner_path;if(!v10SB||!path)return toast('Подтверждённый баннер не загружен');const {data,error}=await v10SB.storage.from('banners').download(path);if(error)return toast('Ошибка скачивания: '+error.message);const url=URL.createObjectURL(data),a=document.createElement('a');a.href=url;a.download='Yaneher_project_banner.'+(path.split('.').pop()||'png');root.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1500)}
root.addEventListener('click',async e=>{
 if(e.target.closest('#v10-signin'))return v10SignIn();
 if(e.target.closest('#v10-signout')){await v10SB?.auth.signOut();return}
 if(e.target.closest('#v10-post-message'))return v10Post();
 if(e.target.closest('#v10-refresh-chat'))return v10LoadChat();
 if(e.target.closest('#v10-banner-download')||e.target.closest('#v10-rules-banner-download'))return v10DownloadBanner();
 if(e.target.closest('#v10-admin-save-settings'))return v10AdminAction('settings');
 if(e.target.closest('#v10-member-add'))return v10AdminAction('member');
 if(e.target.closest('#v10-video-add'))return v10AdminAction('video');
 if(e.target.closest('#v10-upload-banner'))return v10AdminAction('banner');
 const delMember=e.target.closest('[data-removemember]');if(delMember&&v10Admin&&confirm('Удалить участника?')){const {error}=await v10SB.from('members').delete().eq('id',delMember.dataset.removemember);if(error)toast(error.message);else v10LoadMembers();return}
 const delVideo=e.target.closest('[data-removevideo]');if(delVideo&&v10Admin&&confirm('Убрать видео из подборки?')){const {error}=await v10SB.from('featured_videos').delete().eq('id',delVideo.dataset.removevideo);if(error)toast(error.message);else v10LoadFeatured();return}
 const complain=e.target.closest('[data-report]');if(complain){if(!v10User)return toast('Войди, чтобы оставить жалобу');const reason=prompt('Причина жалобы (необязательно):','Нарушение правил');if(reason===null)return;const {error}=await v10SB.from('chat_reports').insert({message_id:complain.dataset.report,reporter_id:v10User.id,reason:reason.slice(0,250)||'Жалоба пользователя'});toast(error?error.message:'Жалоба отправлена');return}
 const resolve=e.target.closest('[data-resolve]');if(resolve&&v10Admin){await v10SB.from('chat_reports').update({resolved:true}).eq('id',resolve.dataset.resolve);v10LoadReports();return}
 const hide=e.target.closest('[data-hidechat]');if(hide&&v10Admin&&confirm('Скрыть сообщение?')){await v10SB.from('chat_messages').update({removed:true}).eq('id',hide.dataset.hidechat);v10LoadReports();v10LoadChat();return}
 const discuss=e.target.closest('[data-discussvideo]');if(discuss){const f=(root._v10Featured||[]).find(x=>String(x.id)===discuss.dataset.discussvideo);if(!f)return;go('ai');$('#y9-question').value=`Разбери, чем полезно для монтажа это видео: ${f.title}, автор ${f.author}. Ссылка: ${f.source_url}. Описание: ${f.description}. Не заявляй, что просмотрел видео, если не получал его кадры.`;return}
});
v10InitCommunity();
