-- Yaneher Community v11: apply AFTER db/supabase.sql in Supabase SQL Editor.
-- Safe for a new deployment when combined with db/INSTALL_ALL.sql.
-- Supabase Auth (email + password), Postgres RLS, SECURITY DEFINER checks.
create extension if not exists pgcrypto;

alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists language text not null default 'ru';
alter table public.profiles add column if not exists theme text not null default 'light';
alter table public.profiles add column if not exists social_links jsonb not null default '{}'::jsonb;
alter table public.profiles add column if not exists is_banned boolean not null default false;
alter table public.profiles add column if not exists chat_muted_until timestamptz;
alter table public.profiles add column if not exists last_seen_at timestamptz;
alter table public.profiles add column if not exists activity_seconds integer not null default 0;
alter table public.profiles add column if not exists last_activity_ping timestamptz;
alter table public.profiles add column if not exists ai_last_used timestamptz;
update public.profiles set username='user_'||replace(left(id::text,13),'-','') where username is null;
alter table public.profiles alter column username set not null;
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check(role in ('user','clipper','admin'));
create unique index if not exists profiles_username_casefold on public.profiles(lower(username));
create index if not exists profiles_role_idx on public.profiles(role);

-- When registering, the nickname is supplied as user_metadata.username.
-- The email is managed by Supabase Auth and never exposed in public.profiles.
create or replace function public.new_user_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
declare nick text;
begin
 nick := trim(coalesce(new.raw_user_meta_data->>'username',''));
 if nick !~ '^[a-zA-Z0-9_]{3,24}$' then
   raise exception 'Никнейм: 3–24 латинских буквы, цифры или _';
 end if;
 insert into public.profiles(id,username,display_name,role)
 values(new.id,nick,nick,'user');
 return new;
end $$;
-- Existing v10 trigger calls the replaced function.

create table if not exists public.admin_logs (
 id bigint generated always as identity primary key,
 actor_id uuid references public.profiles(id) on delete set null,
 target_id uuid,
 action text not null,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists admin_logs_recent on public.admin_logs(created_at desc);
alter table public.admin_logs enable row level security;
drop policy if exists logs_admin_read on public.admin_logs;
create policy logs_admin_read on public.admin_logs for select to authenticated using(public.is_admin());
-- Only security-definer functions below may insert into admin_logs.

create or replace function public.v11_admin_action(
 action_name text, target_user uuid, reason_text text default '', mute_seconds integer default 0
) returns void language plpgsql security definer set search_path='' as $$
declare target_role text;
begin
 if not public.is_admin() then raise exception 'Доступ запрещён'; end if;
 select role into target_role from public.profiles where id=target_user for update;
 if target_role is null then raise exception 'Участник не найден'; end if;
 if target_user=(select auth.uid()) and action_name in ('ban','role_user','role_clipper') then
   raise exception 'Нельзя заблокировать или понизить собственный аккаунт';
 end if;
 if action_name='role_user' then
   update public.profiles set role='user' where id=target_user;
 elsif action_name='role_clipper' then
   update public.profiles set role='clipper' where id=target_user;
 elsif action_name='role_admin' then
   update public.profiles set role='admin' where id=target_user;
 elsif action_name='ban' then
   update public.profiles set is_banned=true where id=target_user;
 elsif action_name='unban' then
   update public.profiles set is_banned=false where id=target_user;
 elsif action_name='mute' then
   if mute_seconds not in (300,600,1800,604800) then raise exception 'Неверный срок ограничения'; end if;
   update public.profiles set chat_muted_until=now()+make_interval(secs=>mute_seconds) where id=target_user;
 elsif action_name='unmute' then
   update public.profiles set chat_muted_until=null where id=target_user;
 else raise exception 'Неизвестное действие'; end if;
 insert into public.admin_logs(actor_id,target_id,action,details)
 values((select auth.uid()),target_user,action_name,jsonb_build_object('reason',left(reason_text,500),'seconds',mute_seconds));
end $$;
revoke all on function public.v11_admin_action(text,uuid,text,integer) from public;
grant execute on function public.v11_admin_action(text,uuid,text,integer) to authenticated;

-- User-editable fields are controlled by a fixed RPC. No direct UPDATE policy for profiles.
create or replace function public.v11_update_profile(
 new_name text, new_avatar text, new_socials jsonb, new_language text, new_theme text
) returns void language plpgsql security definer set search_path='' as $$
begin
 if (select auth.uid()) is null then raise exception 'Требуется вход'; end if;
 if new_name !~ '^[a-zA-Z0-9_]{3,24}$' then raise exception 'Ник: 3–24 символа, A-Z, 0-9, _'; end if;
 if new_avatar is not null and new_avatar<>'' and (length(new_avatar)>500 or new_avatar !~ '^https://') then raise exception 'Аватар: только HTTPS'; end if;
 if new_language not in ('ru','uk','en') or new_theme not in ('light','dark') then raise exception 'Настройки неверны'; end if;
 if jsonb_typeof(new_socials)<>'object' or length(new_socials::text)>1500 then raise exception 'Ссылки неверны'; end if;
 if exists(select 1 from public.profiles where id=(select auth.uid()) and is_banned) then raise exception 'Аккаунт заблокирован'; end if;
 update public.profiles set username=new_name,display_name=new_name,avatar_url=nullif(new_avatar,''),
   social_links=new_socials,language=new_language,theme=new_theme where id=(select auth.uid());
end $$;
revoke all on function public.v11_update_profile(text,text,jsonb,text,text) from public;
grant execute on function public.v11_update_profile(text,text,jsonb,text,text) to authenticated;

create or replace function public.v11_activity_ping() returns void language plpgsql security definer set search_path='' as $$
declare last_ping timestamptz;
begin
 if (select auth.uid()) is null then return; end if;
 select last_activity_ping into last_ping from public.profiles where id=(select auth.uid()) for update;
 if last_ping is null then
   update public.profiles set last_activity_ping=now(),last_seen_at=now() where id=(select auth.uid());
 elsif last_ping<=now()-interval '45 seconds' then
   update public.profiles set activity_seconds=activity_seconds+least(60,greatest(0,floor(extract(epoch from now()-last_ping))::integer)),
     last_activity_ping=now(),last_seen_at=now() where id=(select auth.uid());
 end if;
end $$;
revoke all on function public.v11_activity_ping() from public;
grant execute on function public.v11_activity_ping() to authenticated;

-- Server-atomic 60s AI cooldown, invoked ONLY after authenticating user at the function.
create or replace function public.v11_claim_ai() returns integer
language plpgsql security definer set search_path='' as $$
declare last_request timestamptz; blocked boolean; wait_seconds integer;
begin
 if (select auth.uid()) is null then raise exception 'Требуется вход'; end if;
 select ai_last_used,is_banned into last_request,blocked
 from public.profiles where id=(select auth.uid()) for update;
 if blocked is null or blocked then raise exception 'Аккаунт заблокирован или не найден'; end if;
 wait_seconds:=greatest(0,ceil(60-extract(epoch from now()-coalesce(last_request,now()-interval '61 seconds')))::integer);
 if wait_seconds>0 then return wait_seconds; end if;
 update public.profiles set ai_last_used=now() where id=(select auth.uid());
 return 0;
end $$;
revoke all on function public.v11_claim_ai() from public;
grant execute on function public.v11_claim_ai() to authenticated;

alter table public.chat_messages add column if not exists reply_to uuid references public.chat_messages(id) on delete set null;
alter table public.chat_reports add column if not exists status text not null default 'open';
alter table public.chat_reports add column if not exists admin_note text not null default '';
alter table public.chat_reports add column if not exists handled_by uuid references public.profiles(id) on delete set null;
update public.chat_reports set status='resolved' where resolved;

-- Replaces the existing 5s trigger, adding bans/mutes and row locking against concurrent posts.
create or replace function public.chat_rate_limit() returns trigger
language plpgsql security definer set search_path='' as $$
declare p record;
begin
 select role,is_banned,chat_muted_until into p from public.profiles where id=new.author_id for update;
 if not found then raise exception 'Профиль не найден'; end if;
 if p.is_banned then raise exception 'Аккаунт заблокирован'; end if;
 if p.chat_muted_until>now() then raise exception 'Чат закрыт до %',p.chat_muted_until; end if;
 if p.role<>'admin' and exists(
   select 1 from public.chat_messages where author_id=new.author_id and created_at>now()-interval '5 seconds'
 ) then raise exception 'Подожди 5 секунд перед следующим сообщением'; end if;
 return new;
end $$;
-- Old trigger chat_throttle automatically uses replaced function.

drop policy if exists messages_read on public.chat_messages;
create policy messages_read on public.chat_messages for select to authenticated
 using((not removed and exists(select 1 from public.profiles where id=(select auth.uid()) and not is_banned)) or public.is_admin());
drop policy if exists messages_write on public.chat_messages;
create policy messages_write on public.chat_messages for insert to authenticated
 with check(author_id=(select auth.uid()) and not removed
 and exists(select 1 from public.profiles where id=(select auth.uid()) and not is_banned));
drop policy if exists reports_insert on public.chat_reports;
create policy reports_insert on public.chat_reports for insert to authenticated
 with check(reporter_id=(select auth.uid()) and not resolved and status='open'
 and exists(select 1 from public.profiles where id=(select auth.uid()) and not is_banned)
 and exists(select 1 from public.chat_messages where id=message_id and author_id<>(select auth.uid()) and not removed));

create or replace function public.v11_handle_report(report_id uuid, decision text, note text default '')
returns void language plpgsql security definer set search_path='' as $$
declare msg_id uuid;
begin
 if not public.is_admin() then raise exception 'Доступ запрещён'; end if;
 select message_id into msg_id from public.chat_reports where id=report_id for update;
 if not found then raise exception 'Жалоба не найдена'; end if;
 if decision not in ('resolved','dismissed','remove') then raise exception 'Неверное решение'; end if;
 update public.chat_reports set resolved=true,status=case when decision='remove' then 'resolved' else decision end,
  admin_note=left(note,500),handled_by=(select auth.uid()) where id=report_id;
 if decision='remove' then update public.chat_messages set removed=true where id=msg_id; end if;
 insert into public.admin_logs(actor_id,action,details)
 values((select auth.uid()),'report.'||decision,jsonb_build_object('report_id',report_id,'message_id',msg_id,'note',left(note,500)));
end $$;
revoke all on function public.v11_handle_report(uuid,text,text) from public;
grant execute on function public.v11_handle_report(uuid,text,text) to authenticated;

create table if not exists public.releases (
 id bigint generated always as identity primary key,
 version integer not null unique check(version>0),
 title text not null check(length(title) between 3 and 140),
 description text not null default '',
 changes text not null default '',
 source_tag text,
 is_published boolean not null default false,
 published_at timestamptz,
 created_at timestamptz not null default now()
);
alter table public.releases enable row level security;
drop policy if exists release_read on public.releases;
create policy release_read on public.releases for select to authenticated using(is_published or public.is_admin());
drop policy if exists release_admin_write on public.releases;
create policy release_admin_write on public.releases for all to authenticated
 using(public.is_admin()) with check(public.is_admin());
-- v1 is an unpublished *draft* until owner confirms the deploy works.
insert into public.releases(version,title,description,changes,is_published)
values(1,'Новый интерфейс и аккаунты','Черновик: опубликуйте после проверки релиза','Светлая и тёмная темы; аккаунты Supabase; общий чат; жалобы; управление',false)
on conflict(version) do nothing;

create table if not exists public.lessons (
 id uuid primary key default gen_random_uuid(),
 category text not null,
 difficulty text not null default 'beginner' check(difficulty in ('beginner','intermediate','advanced')),
 title_i18n jsonb not null default '{}'::jsonb,
 summary_i18n jsonb not null default '{}'::jsonb,
 content_i18n jsonb not null default '{}'::jsonb,
 video_url text,
 sort_order integer not null default 0,
 is_published boolean not null default false,
 created_at timestamptz not null default now()
);
alter table public.lessons enable row level security;
drop policy if exists lessons_read on public.lessons;
create policy lessons_read on public.lessons for select to authenticated using(is_published or public.is_admin());
drop policy if exists lessons_admin_write on public.lessons;
create policy lessons_admin_write on public.lessons for all to authenticated using(public.is_admin()) with check(public.is_admin());

create table if not exists public.video_submissions (
 id uuid primary key default gen_random_uuid(),
 author_id uuid not null references public.profiles(id) on delete cascade,
 title text not null check(length(title) between 3 and 120),
 description text not null default '' check(length(description)<=800),
 source_url text not null check(source_url ~ '^https://'),
 author_credit text not null check(length(author_credit) between 2 and 100),
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 review_reason text,
 reviewed_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 reviewed_at timestamptz
);
alter table public.video_submissions enable row level security;
drop policy if exists submission_read on public.video_submissions;
create policy submission_read on public.video_submissions for select to authenticated using(author_id=(select auth.uid()) or public.is_admin());
drop policy if exists submission_insert on public.video_submissions;
create policy submission_insert on public.video_submissions for insert to authenticated
 with check(author_id=(select auth.uid()) and status='pending'
 and exists(select 1 from public.profiles where id=(select auth.uid()) and not is_banned));
alter table public.featured_videos add column if not exists profile_id uuid references public.profiles(id) on delete set null;
alter table public.featured_videos add column if not exists submission_id uuid unique references public.video_submissions(id) on delete set null;

create or replace function public.v11_review_video(item_id uuid, decision text, reason_text text default '')
returns void language plpgsql security definer set search_path='' as $$
declare v record;
begin
 if not public.is_admin() then raise exception 'Доступ запрещён'; end if;
 if decision not in ('approved','rejected') then raise exception 'Неверное решение'; end if;
 select * into v from public.video_submissions where id=item_id and status='pending' for update;
 if not found then raise exception 'Заявка отсутствует или уже рассмотрена'; end if;
 update public.video_submissions set status=decision,review_reason=left(reason_text,500),
  reviewed_by=(select auth.uid()),reviewed_at=now() where id=item_id;
 if decision='approved' then
  insert into public.featured_videos(title,author,source_url,description,profile_id,submission_id)
  values(v.title,v.author_credit,v.source_url,left(v.description,500),v.author_id,item_id);
 end if;
 insert into public.admin_logs(actor_id,target_id,action,details)
 values((select auth.uid()),v.author_id,'video.'||decision,jsonb_build_object('submission',item_id,'reason',left(reason_text,500)));
end $$;
revoke all on function public.v11_review_video(uuid,text,text) from public;
grant execute on function public.v11_review_video(uuid,text,text) to authenticated;

create table if not exists public.video_stats (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.profiles(id) on delete cascade,
 title text not null check(length(title) between 1 and 120),
 posted_on date not null,
 views bigint not null default 0 check(views between 0 and 10000000000),
 source_url text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists video_stats_owner_date on public.video_stats(owner_id,posted_on desc);
alter table public.video_stats enable row level security;
drop policy if exists stats_read on public.video_stats;
create policy stats_read on public.video_stats for select to authenticated using(owner_id=(select auth.uid()) or public.is_admin());
drop policy if exists stats_insert on public.video_stats;
create policy stats_insert on public.video_stats for insert to authenticated with check(owner_id=(select auth.uid()) and
 exists(select 1 from public.profiles where id=(select auth.uid()) and not is_banned));
drop policy if exists stats_update on public.video_stats;
create policy stats_update on public.video_stats for update to authenticated using(owner_id=(select auth.uid()))
 with check(owner_id=(select auth.uid()) and exists(select 1 from public.profiles where id=(select auth.uid()) and not is_banned));
drop policy if exists stats_delete on public.video_stats;
create policy stats_delete on public.video_stats for delete to authenticated using(owner_id=(select auth.uid()));

alter table public.site_settings add column if not exists insert_download_url text;
-- Explicitly no seeded imaginary videos, admin accounts or official rules.
-- Make sure v10 direct-update policies cannot override secure v11 RPC flows.
-- First administrator: in Supabase SQL Editor only, AFTER owner signs up:
-- update public.profiles set role='admin' where id='OWNER_UUID';

-- Audit moderation even when deleting a message directly from an admin view.
create or replace function public.v11_delete_message(message_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not public.is_admin() then raise exception 'Доступ запрещён'; end if;
 update public.chat_messages set removed=true where id=message_id;
 if not found then raise exception 'Сообщение не найдено'; end if;
 insert into public.admin_logs(actor_id,action,details)
 values((select auth.uid()),'chat.message_removed',jsonb_build_object('message_id',message_id));
end $$;
revoke all on function public.v11_delete_message(uuid) from public;
grant execute on function public.v11_delete_message(uuid) to authenticated;

-- Unique migration tokens make importing browser-only v10 records safe to retry.
alter table public.video_stats add column if not exists legacy_id text;
create unique index if not exists video_stats_legacy_once on public.video_stats(owner_id,legacy_id);

-- Private AI history: admins have NO direct access to users' conversations.
create table if not exists public.ai_messages (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.profiles(id) on delete cascade,
 question text not null check(length(question)<=4500),
 answer text not null check(length(answer)<=16000),
 created_at timestamptz not null default now()
);
create index if not exists ai_messages_owner_recent on public.ai_messages(owner_id,created_at desc);
alter table public.ai_messages enable row level security;
drop policy if exists ai_messages_owner_read on public.ai_messages;
create policy ai_messages_owner_read on public.ai_messages for select to authenticated using(owner_id=(select auth.uid()));
drop policy if exists ai_messages_owner_insert on public.ai_messages;
create policy ai_messages_owner_insert on public.ai_messages for insert to authenticated with check(owner_id=(select auth.uid()));
drop policy if exists ai_messages_owner_delete on public.ai_messages;
create policy ai_messages_owner_delete on public.ai_messages for delete to authenticated using(owner_id=(select auth.uid()));

-- Register events in logs; avoid exposing passwords or auth user emails.
create or replace function public.v11_registration_audit() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.admin_logs(actor_id,target_id,action,details)
 values(null,new.id,'user.registered',jsonb_build_object('username',new.username));
 return new;
end $$;
drop trigger if exists v11_profile_registered on public.profiles;
create trigger v11_profile_registered after insert on public.profiles
for each row execute function public.v11_registration_audit();

-- On new lesson/release/settings/video records, record admin actions to audit log.
create or replace function public.v11_content_audit() returns trigger
language plpgsql security definer set search_path='' as $$
declare event_row jsonb;
begin
 if TG_OP='DELETE' then
   event_row:=to_jsonb(old);
 else
   event_row:=to_jsonb(new);
 end if;
 insert into public.admin_logs(actor_id,action,details)
 values((select auth.uid()),TG_TABLE_NAME||'.'||lower(TG_OP),
   jsonb_build_object('id',coalesce(event_row->>'id','main')));
 if TG_OP='DELETE' then return old; end if;
 return new;
end $$;
drop trigger if exists v11_lessons_audit on public.lessons;
create trigger v11_lessons_audit after insert or update or delete on public.lessons
for each row execute function public.v11_content_audit();
drop trigger if exists v11_releases_audit on public.releases;
create trigger v11_releases_audit after insert or update or delete on public.releases
for each row execute function public.v11_content_audit();
drop trigger if exists v11_settings_audit on public.site_settings;
create trigger v11_settings_audit after update on public.site_settings
for each row execute function public.v11_content_audit();

-- Explicit REST privileges; RLS policies still determine actual allowed rows.
grant select,insert,update,delete on public.releases, public.lessons, public.video_submissions,
 public.video_stats, public.ai_messages, public.admin_logs to authenticated;
grant usage,select on all sequences in schema public to authenticated;


-- Private full-video analysis reports for follow-up questions about timestamps.
create table if not exists public.ai_reports (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references public.profiles(id) on delete cascade,
 title text not null check(length(title)<=160),
 report jsonb not null,
 created_at timestamptz not null default now()
);
create index if not exists ai_reports_owner_recent on public.ai_reports(owner_id,created_at desc);
alter table public.ai_reports enable row level security;
drop policy if exists ai_reports_read on public.ai_reports;
create policy ai_reports_read on public.ai_reports for select to authenticated using(owner_id=(select auth.uid()));
drop policy if exists ai_reports_insert on public.ai_reports;
create policy ai_reports_insert on public.ai_reports for insert to authenticated with check(owner_id=(select auth.uid()));
drop policy if exists ai_reports_delete on public.ai_reports;
create policy ai_reports_delete on public.ai_reports for delete to authenticated using(owner_id=(select auth.uid()));
grant select,insert,delete on public.ai_reports to authenticated;

-- Protected administrator check: a banned administrator cannot bypass a ban.
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=(select auth.uid()) and role='admin' and not is_banned);
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated,anon;

-- Public aggregates only; private video rows and AI history stay inaccessible to other users.
create or replace function public.v11_public_profile_stats(target_user uuid)
returns table(message_count bigint, video_count bigint, view_count numeric)
language sql stable security definer set search_path='' as $$
 select
  (select count(*) from public.chat_messages where author_id=target_user and not removed)::bigint,
  (select count(*) from public.featured_videos where profile_id=target_user)::bigint,
  (select coalesce(sum(views),0) from public.video_stats where owner_id=target_user and views>=5000)::numeric;
$$;
revoke all on function public.v11_public_profile_stats(uuid) from public;
grant execute on function public.v11_public_profile_stats(uuid) to authenticated;
