/* Real AI when Netlify function is configured; honest offline fallback otherwise. */
let v10AiCode='';const v10Function=v10Config.aiFunction||'/.netlify/functions/yaneai';
try{v10AiCode=sessionStorage.getItem('YaneCLIBB_AI_code')||''}catch(e){}
async function v10CheckAI(){if(location.protocol==='file:')return;try{const res=await fetch(v10Function,{method:'GET',cache:'no-store'});if(!res.ok)return;const data=await res.json();v10BackendReady=!!data.configured;if(v10BackendReady){v10Status.textContent='ИИ-сервер доступен. Код доступа вводится при первом запросе. При отправке кадров они будут переданы API-провайдеру.';$('.chathead .pill').textContent='API READY';$('#v10-backend-state').textContent='● ЯнеИИ API доступен';$('#v10-backend-state').classList.add('ready');if(latestReport)$('#v10-ai-analysis').hidden=false}else v10Status.textContent='Настоящий ИИ пока не подключён. Доступны локальные советы и визуальная проверка.'}catch(e){}
}
async function v10RequestAI({mode='chat',message='',frames=[],report=null,history=[]}){
 if(!v10BackendReady)throw Error('ИИ-сервер не настроен.');
 if(!v10AiCode){v10AiCode=prompt('Введи выданный администратором код доступа к ЯнеИИ (не API-ключ):')||'';if(!v10AiCode)throw Error('Код доступа не введён.');try{sessionStorage.setItem('YaneCLIBB_AI_code',v10AiCode)}catch(e){}}
 const request={accessCode:v10AiCode,mode,message,history,frames,report};
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),29000);
 try{const res=await fetch(v10Function,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(request),signal:controller.signal});const body=await res.json().catch(()=>({}));if(!res.ok){if(res.status===401){v10AiCode='';try{sessionStorage.removeItem('YaneCLIBB_AI_code')}catch(e){}}throw Error(body.error||'Ошибка '+res.status)}return body}
 finally{clearTimeout(timer)}
}
// Replace v9 canned chat handler: if real AI configured, include conversation context;
// without server, use clearly labeled local knowledge base without pretending to be generative AI.
sendChat=async function(){
 if(chatBusy)return;const question=$('#y9-question').value.trim(),file=chatFile;
 if(!question&&!file)return;
 chatBusy=true;$('#y9-send').disabled=true;addMsg('Ты',(question||'Разбери прикреплённый файл')+(file?'\n📎 '+file.name:''));
 $('#y9-question').value='';chatFile=null;$('#y9-chatfile').value='';$('#y9-attachline').classList.remove('show');
 const output=addMsg('ЯнеИИ',v10BackendReady?'Обрабатываю запрос через API…':'Готовлю локальный ответ…');
 try{
  let info=null,frames=[],reportData=null;
  if(file){v10Abort=false;info=await inspect(file);const r=report(info);reportData={name:file.name,width:info.w,height:info.h,duration:info.duration,sampledFrames:info.samples.length,issues:r.timeline.slice(0,20)};frames=v10RepresentativeFrames(info.samples,Math.min(14,info.samples.length))}
  let response='';
  if(v10BackendReady){const data=await v10RequestAI({mode:file?'video':'chat',message:question||'Дай визуальный разбор загруженных кадров, объясни что видно и что нельзя оценить.',frames,report:reportData,history:v10MessageHistory.slice(-12)});response=data.answer}
  else if(info){const r=report(info);response=`ЛОКАЛЬНАЯ ПРОВЕРКА (не полноценный ИИ)\n\nФайл: ${info.name}\nРазрешение: ${info.w}×${info.h}\nДлительность: ${info.duration===null?'—':v10Seconds(info.duration)}\nВыборка: ${info.samples.length} кадров по всему таймлайну.\nОценка технических признаков: ${r.score}/100.\n\n${r.timeline.length?'Таймкоды для ручной проверки:\n'+r.timeline.slice(0,7).map(x=>v10Seconds(x.time)+' — '+x.description).join('\n'):'В выборке не обнаружено явных резких изменений.'}\n\nЧего я НЕ сделал: не распознал слова, звук, смысл юмора и фактическое удержание. Для этого необходимо подключить API.\n\n`+(question?answer(question):'Можешь спросить, как исправить конкретные замечания.')}
  else response='ЛОКАЛЬНЫЙ СПРАВОЧНИК (без нейросети)\n\n'+answer(question);
  output.textContent=response;
  v10MessageHistory.push({role:'user',content:question+(file?' [прикреплён файл '+file.name+']':'')},{role:'assistant',content:response});if(v10MessageHistory.length>32)v10MessageHistory=v10MessageHistory.slice(-24);
 }catch(e){output.textContent='Не удалось завершить запрос: '+(e.message||'неизвестная ошибка')+'\n\n'+(v10BackendReady?'Проверь подключение API.':'Попробуй другой формат файла.');}
 finally{chatBusy=false;$('#y9-send').disabled=false;$('#v10-context-count').textContent=Math.ceil(v10MessageHistory.length/2)+' сообщений';$('#y9-messages').scrollTop=$('#y9-messages').scrollHeight;}
};
$('#v10-clear-chat').addEventListener('click',()=>{if(!confirm('Очистить текущий диалог?'))return;v10MessageHistory=[];$('#y9-messages').innerHTML='<div class="bubble"><b>ЯнеИИ</b><div class="content">Диалог очищен. Задай новый вопрос.</div></div>';$('#v10-context-count').textContent='0 сообщений'});
v10CheckAI();
/* Useful real text lessons with distinct PC/mobile workflows. No imaginary video links. */
const v10Lessons=[
 {cat:'mobile',level:'beginner',title:'CapCut на телефоне: первая нарезка',intro:'От исходного стрима до первого вертикального клипа.',steps:['Создай проект, добавь клип и установи формат 9:16.','Найди кульминацию и обрежь весь ненужный разговор до и после.','Оставь 1–2 секунды, которые сразу объясняют интригу; проверь, чтобы они не ломали сюжет.','Добавь короткие читаемые субтитры, не закрывающие интерфейс TikTok.','Проверь звук в наушниках и экспортируй MP4.']},
 {cat:'mobile',level:'beginner',title:'Субтитры без перегруза',intro:'Читаемость важнее количества эффектов.',steps:['Выбери контрастный шрифт и один аккуратный акцентный цвет.','Дели длинные фразы на небольшие смысловые группы.','Проверь расположение текста внутри безопасной зоны вертикального видео.','Просмотри ролик на настоящем телефоне, а не только в редакторе.','Сверь автоматическую расшифровку с оригинальным голосом.']},
 {cat:'mobile',level:'advanced',title:'Ритм и синхронизация на смартфоне',intro:'Точные акценты без случайных переходов.',steps:['Прослушай дорожку, отметь сильные музыкальные акценты.','Вынеси важный момент на сильный ритмический удар, если это уместно.','Меняй длительность кадров по смыслу, а не просто каждые полсекунды.','Проверь, что музыка не перекрывает речь.','Сравни версию с музыкой и без — оставь ту, где момент понятнее.']},
 {cat:'desktop',level:'beginner',title:'CapCut на ПК: от таймлайна к экспорту',intro:'Удобный рабочий процесс для игровых клипов.',steps:['Организуй исходники и отдельную папку экспорта.','Создай вертикальный проект 1080×1920.','На таймлайне сначала собери историю без эффектов.','Добавь аудиокоррекцию и субтитры только после основного монтажа.','Экспортируй H.264 MP4, просмотри файл целиком перед загрузкой.']},
 {cat:'desktop',level:'advanced',title:'Premiere Pro: динамика и J/L cuts',intro:'Тонкая работа со стыками и диалогом.',steps:['Выдели смысловые блоки: хук, контекст, развитие, кульминация, реакция.','Используй ripple trim для удаления пауз без зазоров.','Применяй J-cut или L-cut там, где аудио помогает связать две сцены.','Проверь, чтобы резкий переход был художественным решением, а не ошибкой.','Настрой loudness и делай финальный просмотр в 9:16.']},
 {cat:'desktop',level:'advanced',title:'DaVinci/Premiere: цвет и стабильность',intro:'Не теряй детали интерфейса и тёмных сцен.',steps:['Проверь уровни чёрного и белого на нескольких сценах.','Не поднимай тени так сильно, чтобы появился цифровой шум.','Сравни цветокоррекцию с исходником на одном и том же кадре.','Следи за резкостью мелких элементов игры и текста.','Тестируй экспорт на смартфоне, а не только в окне редактора.']},
 {cat:'all',level:'beginner',title:'Как выбирать лучшие моменты стрима',intro:'Отбор материала до монтажа.',steps:['Отмечай не только крики, но и причину эмоции.','Проверь, сможет ли зритель понять ситуацию без длинного вступления.','Выбирай моменты с понятной развязкой или полезным выводом.','Не искажай контекст ради кликабельности.','Проверь разрешение на использование исходной трансляции.']},
 {cat:'all',level:'advanced',title:'Разбор удержания после публикации',intro:'План проверки реальной статистики.',steps:['Собери длительность, средний просмотр, полный досмотр и удержание по времени.','Сравни ролики одинаковой длительности и тематики, не смешивая все форматы.','Отметь секунды самого большого спада.','Создай следующую нарезку с одной конкретной правкой.','Подведи итоги по нескольким видео, а не по одному случайному охвату.']}
];
function v10RenderLessons(filter='all'){
 const list=v10Lessons.filter(x=>filter==='all'||x.cat===filter||x.level===filter);
 $('#v10-lessons').innerHTML=list.map((x,i)=>`<article class="card v10-lesson"><span class="level">${x.cat==='mobile'?'📱 ТЕЛЕФОН':x.cat==='desktop'?'💻 ПК':'УНИВЕРСАЛЬНО'} · ${x.level==='beginner'?'НОВИЧОК':'ПРОДВИНУТЫЙ'}</span><h3>${esc(x.title)}</h3><p>${esc(x.intro)}</p>${x.steps.map((s,j)=>`<div class="step"><b>${j+1}.</b> ${esc(s)}</div>`).join('')}<div class="actions"><button class="btn sm" data-lessonask="${i}">✦ Уточнить у ЯнеИИ</button></div></article>`).join('')||'<div class="v10-empty">Для этого фильтра пока нет уроков.</div>';
}
root.addEventListener('click',e=>{
 const filter=e.target.closest('[data-learn]');if(filter){$$('[data-learn]').forEach(x=>{x.classList.toggle('primary',x===filter)});v10RenderLessons(filter.dataset.learn);return}
 const ask=e.target.closest('[data-lessonask]');if(ask){const l=v10Lessons[Number(ask.dataset.lessonask)];if(!l)return;go('ai');$('#y9-question').value='Подробно объясни мне урок «'+l.title+'» для '+(l.cat==='mobile'?'телефона':'ПК')+'. Дай дополнительные практические примеры и типичные ошибки.';return}
});
v10RenderLessons();
