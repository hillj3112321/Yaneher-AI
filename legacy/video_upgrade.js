/* V10: timeline inspection. Every segment is sampled across the FULL video duration,
   NOT just the beginning/middle/end. The implementation is intentionally explicit:
   sampling is visual-only and does not measure audio, speech or actual viewer retention. */
let v10Abort=false,v10ActiveMediaInfo=null,v10AiEvidence=null;
const v10Status=$('#v10-ai-status');
function v10Progress(n,limit){const p=$('#v10-progress');p.hidden=false;const pct=Math.min(100,Math.round(n/Math.max(1,limit)*100));$('#v10-progress-label').textContent=`Визуальная выборка по всему ролику: ${n} / ${limit}`;$('#v10-progress-pct').textContent=pct+'%';$('#v10-progressbar').style.width=pct+'%'}
function v10LowResFrame(el,w,h,time){
 const can=document.createElement('canvas'),sc=Math.min(1,160/Math.max(w,h));can.width=Math.max(1,Math.round(w*sc));can.height=Math.max(1,Math.round(h*sc));const ctx=can.getContext('2d',{willReadFrequently:true});ctx.drawImage(el,0,0,can.width,can.height);
 const pixels=ctx.getImageData(0,0,can.width,can.height).data;
 let sum=0,n=0;const vector=[];
 for(let gy=0;gy<8;gy++)for(let gx=0;gx<8;gx++){let ix=Math.min(can.width-1,Math.floor((gx+.5)*can.width/8)),iy=Math.min(can.height-1,Math.floor((gy+.5)*can.height/8)),i=(iy*can.width+ix)*4;let l=.2126*pixels[i]+.7152*pixels[i+1]+.0722*pixels[i+2];vector.push(Math.round(l));sum+=l;n++}
 return{time,brightness:sum/n,vector,thumb:can.toDataURL('image/jpeg',.52)};
}
function v10Diff(a,b){return a.vector.reduce((s,x,i)=>s+Math.abs(x-b.vector[i]),0)/a.vector.length}
function v10SampleTimes(duration){if(!Number.isFinite(duration)||duration<=0)return[0];let step=Math.max(.8,duration/100),count=Math.min(100,Math.max(4,Math.ceil(duration/step)));const times=[];for(let i=0;i<count;i++)times.push(Math.max(0,Math.min(duration-.07,i*(duration-.13)/(count-1))));return times}
inspect=async function(file,progressCallback){
 if(!file||file.size>150*1024*1024)throw Error('Файл больше 150 МБ. Для длинных роликов нужен серверный конвейер.');
 const url=URL.createObjectURL(file);let vid=null;
 try{
 if(file.type.startsWith('image/')){
  const im=new Image(),ready=waitEvent(im,'load','error',14000);im.src=url;await ready;
  const f=v10LowResFrame(im,im.naturalWidth,im.naturalHeight,0);
  return{type:'photo',name:file.name,w:im.naturalWidth,h:im.naturalHeight,duration:null,frames:[f],samples:[f],issues:[],brightness:f.brightness,segments:1,coverage:'Одно изображение'};
 }
 vid=document.createElement('video');vid.preload='auto';vid.muted=true;vid.playsInline=true;let ready=waitEvent(vid,'loadedmetadata','error',16000);vid.src=url;vid.load();await ready;
 const w=vid.videoWidth,h=vid.videoHeight,duration=Number.isFinite(vid.duration)?vid.duration:null;if(!w||!h)throw Error('Браузер не декодирует видео. Попробуй MP4/H.264.');
 const times=v10SampleTimes(duration);const samples=[];let failCount=0;
 for(let k=0;k<times.length;k++){
  if(v10Abort||file!==mediaFile&&file!==chatFile)throw Error('Анализ отменён или выбран другой файл.');
  try{
   let t=times[k];if(Math.abs(vid.currentTime-t)>.04){const seek=waitEvent(vid,'seeked','error',6000);vid.currentTime=t;await seek}
   samples.push(v10LowResFrame(vid,w,h,t));
   failCount=0;
  }catch(e){failCount++;if(failCount>=3)break}
  if(progressCallback)progressCallback(k+1,times.length);
  if(k%6===0)await new Promise(resolve=>setTimeout(resolve,0));
 }
 if(!samples.length){try{samples.push(v10LowResFrame(vid,w,h,0))}catch(e){}}
 const issues=[],changes=[];
 for(let i=1;i<samples.length;i++){
  const score=v10Diff(samples[i-1],samples[i]);
  samples[i].change=score;
  if(score>36)changes.push({time:samples[i].time,kind:'cut',magnitude:score,description:'Сильное изменение изображения между соседними выборками. Возможна смена сцены или резкое движение.'});
  if(samples[i].brightness<32)issues.push({time:samples[i].time,kind:'dark',description:'Очень тёмный участок: проверь, различимы ли детали и текст.'});
  else if(samples[i].brightness>231)issues.push({time:samples[i].time,kind:'bright',description:'Очень светлый участок: проверь пересвет и читаемость титров.'});
  if(score<3&&samples[i].time-samples[i-1].time>=1)issues.push({time:samples[i].time,kind:'still',description:'Почти неизменный кадр между соседними выборками: проверь, нет ли длинной паузы.'});
 }
 const brightness=samples.length?samples.reduce((s,f)=>s+f.brightness,0)/samples.length:null;
 // Thumbnails selected across ALL segments, not first three frames. Keeps UI and memory compact.
 const thumbs=[];const n=Math.min(12,samples.length);for(let i=0;i<n;i++) thumbs.push(samples[Math.round(i*(samples.length-1)/Math.max(1,n-1))]);
 return{type:'video',name:file.name,w,h,duration,frames:thumbs,samples,issues,changes,brightness,segments:samples.length,coverage:`${samples.length} визуальных выборок, от начала до конца`};
 }finally{if(vid){vid.pause();vid.removeAttribute('src');vid.load()}URL.revokeObjectURL(url)}
};
function v10Seconds(n){const s=Math.floor(Math.max(0,n||0));return String(Math.floor(s/60)).padStart(2,'0')+':'+String(s%60).padStart(2,'0')}
report=function(info,checks={}){
 let base=0,positives=[],issues=[],ratio=info.w/info.h;
 if(ratio>.53&&ratio<.62){base+=40;positives.push('Вертикальный формат близок к 9:16.')}else if(ratio<1){base+=22;issues.push('Кадр вертикальный, но отличается от 9:16: проверь безопасные зоны.')}else{base+=7;issues.push('Горизонтальная композиция: проверь кадрирование под вертикальную ленту.')}
 if(info.w>=720&&info.h>=1280){base+=30;positives.push('Разрешение подходит для вертикального ролика.')}else if(Math.max(info.w,info.h)>=960){base+=16;issues.push('Проверь читаемость деталей и титров после экспорта.')}else{base+=6;issues.push('Разрешение ниже рекомендованного для качественного вертикального клипа.')}
 if(info.type==='photo'){base+=8;issues.push('Это изображение: монтаж, ритм, длительность и звук проверить нельзя.')}else if(info.duration&&info.duration>=8&&info.duration<=90){base+=15;positives.push('Длительность в диапазоне коротких видео.')}else{base+=7;issues.push('Проверь темп и длину — автоматический порог не означает плохой сюжет.')}
 if(info.brightness!==null&&info.brightness>=35&&info.brightness<=220){base+=15;positives.push('Средняя яркость выборки без критичных отклонений.')}else{base+=5;issues.push('Некоторые кадры могут быть слишком тёмными или светлыми.')}
 const keys=['rhook','rstory','rtext','raudio','rrights'];let answered=0,passed=0;
 for(const k of keys){if(checks[k]){answered++;if(checks[k]==='yes')passed++;else issues.push(({rhook:'Сильное начало',rstory:'Понятная кульминация',rtext:'Текст',raudio:'Голос и звук',rrights:'Права на материал'})[k]+': укажи, как исправить.')}}
 const tech=Math.min(100,base),rated=answered>=4&&info.type==='video';let verdict='Недостаточно данных',style='',reason='Заполни как минимум 4 пункта чек-листа и проверь сам сюжет. Автоматические значения не отражают реального удержания.';
 if(info.type==='photo'){reason='По фотографии невозможно судить о целом ролике.'}
 else if(rated){if(checks.rrights!=='yes'){verdict='Сначала проверь права';style='bad';reason='Для публикации чужого материала необходимо соответствующее разрешение.'}
 else if(checks.rhook==='no'||checks.rstory==='no'||tech<55){verdict='Нужны доработки';style='bad';reason='По техническим признакам или чек-листу обнаружены замечания.'}
 else if(passed>=4&&tech>=75){verdict='Можно тестировать публикацию';style='ok';reason='По проверенным техническим признакам нет существенных блокеров. Сюжет и звук алгоритм не оценивает.'}
 else{verdict='Желательно доработать';reason='Проверь слабые места и пересмотри ролик вручную.'}}
 let timeline=[];
 for(const event of info.issues||[]){if(timeline.length>=12)break;if(timeline.some(x=>Math.abs(x.time-event.time)<1.2&&x.kind===event.kind))continue;timeline.push(event)}
 for(const event of info.changes||[]){if(timeline.length>=20)break;timeline.push(event)}
 timeline.sort((a,b)=>a.time-b.time);
 const motion=info.samples?.length>1?info.samples.slice(1).map(x=>x.change||0):[];
 const changing=motion.filter(x=>x>36).length;
 let categories={Монтаж:null,Динамика:motion.length?Math.min(10,Math.max(2,Math.round(5+(changing/motion.length-.17)*12))):null,Звук:null,Визуал:Math.max(0,Math.min(10,Math.round(tech/10))),Внимание:null};
 // No objective montage/audio/attention score from sparsely sampled screenshots.
 return{info,score:tech,answered,positives,issues,verdict,style,reason,timeline,categories};
};
renderReport=function(r){
 const i=r.info;const rows=Object.entries(r.categories).map(([name,value])=>`<div class="v10-score"><small>${esc(name)}</small><strong>${value===null?'—':value+'/10'}</strong></div>`).join('');
 const thumbs=(i.frames||[]).length?`<h3>Кадры из разных частей ролика</h3><div class="frames">${i.frames.map(f=>`<div><button class="v10-framebutton" data-seek="${f.time}" type="button" title="Перейти к ${v10Seconds(f.time)}"><img src="${f.thumb}" alt="Кадр ${v10Seconds(f.time)}"><small>${v10Seconds(f.time)}</small></button></div>`).join('')}</div>`:'';
 $('#y9-reviewout').innerHTML=`<div class="overline">TIMELINE / VISUAL AUDIT</div><h3 style="overflow-wrap:anywhere;margin-top:12px">${esc(i.name)}</h3><p>${i.w}×${i.h} · ${i.duration===null?'Фото':v10Seconds(i.duration)+' · '+i.segments+' выборок'}</p><div class="verdict ${r.style}"><strong>${r.verdict}</strong><p>${r.reason}</p></div><div class="overline">ТЕХНИЧЕСКАЯ ОЦЕНКА: ${r.score}/100</div><div class="meter"><div style="width:${r.score}%"></div></div><div class="v10-report-grid">${rows}</div><p class="v10-fine">Прочерки означают, что показатель нельзя оценить автоматически. «Динамика» — только изменение изображения между выборками, не качество ритма монтажа и не фактическое удержание.</p><h3>Таймкоды для ручной проверки</h3>${r.timeline.length?r.timeline.map(t=>`<button class="v10-timecode" data-seek="${t.time}" type="button"><b>${v10Seconds(t.time)}</b><span>${esc(t.description)}</span></button>`).join(''):'<p>Явных перепадов изображения не обнаружено. Это не доказывает отсутствие проблем с монтажом.</p>'}<h3 style="margin-top:16px">Замечания</h3><ul class="items">${r.issues.map(t=>'<li>'+esc(t)+'</li>').join('')||'<li>Критичных технических замечаний нет.</li>'}</ul><h3>Положительные признаки</h3><ul class="items">${r.positives.map(t=>'<li>'+esc(t)+'</li>').join('')}</ul>${thumbs}<div class="actions"><button class="btn primary" type="button" id="y9-askreport">✦ Обсудить с ЯнеИИ</button><button class="btn" type="button" id="v10-review-ai-request">✦ Содержательный ИИ-разбор</button></div><p class="v10-fine">Кнопки с таймкодами перематывают встроенный плеер. Реальные субтитры, слова, звук и качество юмора без внешней модели не определяются.</p>`;
};
analyze=async function(){if(analyzing||!mediaFile)return;analyzing=true;v10Abort=false;const file=mediaFile;
 $('#y9-analyze').disabled=true;$('#y9-analyze').textContent='Идёт анализ…';$('#v10-cancel-analysis').hidden=false;$('#v10-ai-analysis').hidden=true;
 $('#y9-reviewout').innerHTML='<div class="resultempty"><i>◌</i><h3>Прохожу по таймлайну</h3><p>Выборка выполняется от начала до конца ролика.</p></div>';
 const checks=Object.fromEntries(['rhook','rstory','rtext','raudio','rrights'].map(k=>[k,$('#y9-'+k).value]));
 try{const info=await inspect(file,v10Progress);if(file!==mediaFile||v10Abort)return;latestReport=report(info,checks);v10ActiveMediaInfo=info;renderReport(latestReport);$('#v10-ai-analysis').hidden=!v10BackendReady}
 catch(e){if(!v10Abort)$('#y9-reviewout').innerHTML=`<div class="verdict bad"><strong>Не удалось проанализировать файл</strong><p>${esc(e.message)}. Попробуй MP4/H.264 либо WebM.</p></div>`}
 finally{analyzing=false;$('#y9-analyze').disabled=false;$('#y9-analyze').textContent='✦ Начать проверку';$('#v10-cancel-analysis').hidden=true;$('#v10-progress').hidden=true}
};
$('#v10-cancel-analysis').addEventListener('click',()=>{v10Abort=true;toast('Операция отменена')});
root.addEventListener('click',e=>{
 const jump=e.target.closest('[data-seek]');if(jump){const video=$('#y9-mediapreview video');if(video){const n=Number(jump.dataset.seek);if(Number.isFinite(n)&&n>=0){video.currentTime=n;video.play().catch(()=>{})}}else toast('Нужен видеоплеер');return}
 if(e.target.closest('#v10-review-ai-request')||e.target.closest('#v10-ai-analysis')){v10DetailedAI();return}
},true);
async function v10DetailedAI(){if(!latestReport){toast('Сначала проведи локальную проверку');return}if(!v10BackendReady){toast('Для настоящего анализа нужен API');return}
 const r=latestReport,i=r.info,el=$('#y9-reviewout');const btn=$('#v10-review-ai-request');if(btn){btn.disabled=true;btn.textContent='ИИ анализирует кадры…'}
 try{
 const samples=i.samples||i.frames;const frames=v10RepresentativeFrames(samples,Math.min(18,samples.length));
 const data=await v10RequestAI({mode:'video',message:'Составь детальный разбор доступных кадров и таймкодов. Не приписывай несмотренные детали. Про звук и фактическое удержание напиши «неизвестно». Дай советы для CapCut/Premiere по наблюдаемым визуальным проблемам.',frames,report:{name:i.name,width:i.w,height:i.h,duration:i.duration,sampleCount:samples.length,timeline:r.timeline.slice(0,24),technicalScore:r.score}});
 v10AiEvidence=data.answer;
 const block=document.createElement('div');block.className='panel';block.style.marginTop='17px';
 const h=document.createElement('h3');h.textContent='✦ Разбор мультимодальной модели';const pre=document.createElement('div');pre.className='v10-report-pre';pre.textContent=data.answer;const note=document.createElement('p');note.className='v10-fine';note.textContent=`Модель получила ${frames.length} кадров, выбранных из ${samples.length} визуальных выборок. Звуковая дорожка в неё не передавалась.`;block.append(h,pre,note);el.append(block);block.scrollIntoView?.({behavior:'smooth',block:'nearest'});
 }catch(err){toast('ИИ: '+(err.message||'ошибка соединения'))}
 finally{if(btn){btn.disabled=false;btn.textContent='✦ Содержательный ИИ-разбор'}}
}
function v10RepresentativeFrames(samples,max){if(!samples.length)return[];const n=Math.min(max,samples.length);return Array.from({length:n},(_,i)=>{const f=samples[Math.round(i*(samples.length-1)/Math.max(1,n-1))];return{time:Math.round(f.time*10)/10,image:f.thumb}})}
