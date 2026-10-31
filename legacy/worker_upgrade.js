/* Optional FFmpeg-powered full-video and audio metadata worker. */
let v10WorkerReport=null,v10WorkerXHR=null,v10WorkerCode='';
try{v10WorkerCode=sessionStorage.getItem('YaneCLIBB_worker_code')||''}catch(e){}
if(v10Config.videoWorkerUrl){
 const btn=document.createElement('button');btn.type='button';btn.className='btn primary';btn.id='v10-worker-analyze';btn.textContent='▣ Серверный анализ всего файла';
 $('#y9-analyze').insertAdjacentElement('afterend',btn);
 const info=document.createElement('p');info.className='v10-fine';info.textContent='Серверный режим: весь файл будет отправлен на отдельный защищённый видеосервер. Он определит FPS, склейки и уровни звука с помощью FFmpeg. Перед отправкой требуется твой код доступа.';
 $('#y9-reviewout').insertAdjacentElement('afterend',info);
}
function v10WorkerRequest(file){
 return new Promise((resolve,reject)=>{
  const base=v10Config.videoWorkerUrl.replace(/\/$/,'');if(!/^https:\/\//i.test(base))return reject(Error('Адрес видеосервера должен использовать HTTPS.'));
  const xhr=new XMLHttpRequest();v10WorkerXHR=xhr;
  xhr.open('POST',base+'/analyze',true);xhr.setRequestHeader('Authorization','Bearer '+v10WorkerCode);xhr.timeout=180000;
  xhr.upload.onprogress=e=>{if(!e.lengthComputable)return;v10Progress(Math.round(e.loaded/e.total*100),100);$('#v10-progress-label').textContent='Загрузка видео на сервер…'};
  xhr.onload=()=>{let data;try{data=JSON.parse(xhr.responseText)}catch(e){return reject(Error('Некорректный ответ сервера'))}if(xhr.status>=200&&xhr.status<300)resolve(data);else reject(Error(data.detail||data.error||'HTTP '+xhr.status))};
  xhr.onerror=()=>reject(Error('Не удалось подключиться к серверу или запрещён CORS'));
  xhr.ontimeout=()=>reject(Error('Превышено время серверного анализа'));
  xhr.onabort=()=>reject(Error('Загрузка отменена'));
  const form=new FormData();form.append('file',file,file.name);xhr.send(form);
 });
}
async function v10RunWorker(){
 if(!mediaFile||!mediaFile.type.startsWith('video/'))return toast('Выбери видео для серверного анализа');
 if(!v10WorkerCode){v10WorkerCode=prompt('Код доступа к видеосерверу (не API-ключ):')||'';if(!v10WorkerCode)return;try{sessionStorage.setItem('YaneCLIBB_worker_code',v10WorkerCode)}catch(e){}}
 const btn=$('#v10-worker-analyze');btn.disabled=true;$('#v10-progress').hidden=false;$('#v10-progress-label').textContent='Подготовка…';const file=mediaFile;
 try{const response=await v10WorkerRequest(file);if(file!==mediaFile)return;v10WorkerReport=response;v10RenderWorker(response)}
 catch(e){if(/код доступа|401/i.test(e.message)){v10WorkerCode='';try{sessionStorage.removeItem('YaneCLIBB_worker_code')}catch(x){}}toast(e.message)}
 finally{v10WorkerXHR=null;btn.disabled=false;$('#v10-progress').hidden=true}
}
function v10RenderWorker(r){
 const {metadata:m,audio,sceneCuts=[],visual}=r;
 const cutTimes=sceneCuts.slice(0,60).map(t=>`<button type="button" class="v10-timecode" data-seek="${t}"><b>${v10Seconds(t)}</b><span>FFmpeg обнаружил вероятную смену сцены по визуальному порогу. Это может быть и сильное движение.</span></button>`).join('');
 const silences=(audio?.silences||[]).slice(0,40).map(x=>`<button type="button" class="v10-timecode" data-seek="${x.start}"><b>${v10Seconds(x.start)}–${v10Seconds(x.end)}</b><span>По данным аудиофильтра здесь обнаружена относительная тишина (ниже −32 dB). Проверь, уместна ли пауза.</span></button>`).join('');
 const rootEl=$('#y9-reviewout');const area=document.createElement('section');area.className='panel';area.id='v10-worker-report';area.style.marginTop='16px';
 area.innerHTML=`<span class="tag">FULL TIMELINE / FFMPEG</span><h3 style="margin-top:12px">Серверный технический анализ</h3><div class="v10-report-grid"><div class="v10-score"><small>FPS</small><strong>${m.fps===null?'—':m.fps}</strong></div><div class="v10-score"><small>Декодер</small><strong style="font-size:15px">${esc(m.videoCodec||'—')}</strong></div><div class="v10-score"><small>Кадров выборки</small><strong>${visual?.samples?.length||0}</strong></div><div class="v10-score"><small>Найдено склеек</small><strong>${sceneCuts.length}</strong></div><div class="v10-score"><small>Участков тишины</small><strong>${audio?.silences?.length||0}</strong></div><div class="v10-score"><small>Громкость LUFS</small><strong>${audio?.integratedLufs===null?'—':audio.integratedLufs}</strong></div></div><p class="v10-fine">${esc(r.limitations||'Это технические измерения, не интерпретация эмоций.')}</p><h3>Возможные переходы (${sceneCuts.length})</h3>${cutTimes||'<p>По выбранному порогу явные склейки не найдены.</p>'}<h3 style="margin-top:18px">Паузы аудиодорожки</h3>${silences||'<p>Паузы не обнаружены или аудиодорожка отсутствует.</p>'}<h3 style="margin-top:18px">Визуальные замечания</h3>${(visual?.events||[]).slice(0,35).map(x=>`<button type="button" class="v10-timecode" data-seek="${x.time}"><b>${v10Seconds(x.time)}</b><span>${esc(x.note)}</span></button>`).join('')||'<p>Явных технических замечаний в выбранной выборке нет.</p>'}<div class="actions"><button class="btn primary" id="v10-worker-discuss">✦ Подробный разбор с ЯнеИИ</button></div>`;
 rootEl.appendChild(area);area.scrollIntoView?.({behavior:'smooth',block:'nearest'});
}
root.addEventListener('click',e=>{
 if(e.target.closest('#v10-worker-analyze'))return v10RunWorker();
 if(e.target.closest('#v10-worker-discuss')){
  if(!v10WorkerReport)return;
  if(v10BackendReady){v10WorkerAIDiscuss();return}
  go('ai');$('#y9-question').value='Объясни мои технические данные FFmpeg и как исправить найденные проблемы: '+JSON.stringify(v10WorkerReport).slice(0,3000);toast('Настоящий ИИ требует подключённый API.');
 }
});
async function v10WorkerAIDiscuss(){
 const r=v10WorkerReport;if(!r)return;
 const images=(r.visual?.representativeFrames||[]).slice(0,18);
 go('ai');const prompt='Содержательно разберите визуальные кадры и реальный отчёт FFmpeg: FPS, сцены, паузы и среднюю громкость. Не утверждайте, что расшифровали речь. Дайте конкретные рекомендации с таймкодами для CapCut/Premiere.';
 addMsg('Ты',prompt);const el=addMsg('ЯнеИИ','Собираю визуальный и аудиотехнический отчёт…');
 try{const result=await v10RequestAI({mode:'video',message:prompt,frames:images,report:{metadata:r.metadata,scenes:r.sceneCuts,audio:r.audio,visualEvents:r.visual?.events},history:v10MessageHistory.slice(-12)});el.textContent=result.answer;v10MessageHistory.push({role:'user',content:prompt},{role:'assistant',content:result.answer})}catch(e){el.textContent='Ошибка API: '+e.message}
}
