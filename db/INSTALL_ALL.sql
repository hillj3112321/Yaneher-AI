-- New Supabase: run ALL of this once in SQL Editor.
-- Existing v10 Supabase: run v11_upgrade.sql THEN seed_lessons.sql instead.

-- Yaneher Chat v10: run in Supabase SQL Editor once.
-- Do not paste service_role keys into browser code.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null default 'Участник' check(char_length(display_name) between 1 and 60),
 avatar_url text,
 role text not null default 'user' check(role in ('user','admin')),
 created_at timestamptz not null default now()
);
create table if not exists public.site_settings (
 id text primary key default 'main' check(id='main'),
 capacity integer not null default 10 check(capacity between 1 and 1000),
 official_rules text not null default '' check(char_length(official_rules)<=25000),
 extra_rules text not null default '' check(char_length(extra_rules)<=25000),
 banner_path text,
 updated_at timestamptz not null default now()
);
insert into public.site_settings(id) values('main') on conflict(id) do nothing;
create table if not exists public.members (
 id uuid primary key default gen_random_uuid(),
 nickname text not null check(char_length(nickname) between 1 and 60),
 username text not null unique check(char_length(username) between 2 and 60),
 avatar_url text,
 status text not null default 'new' check(status in ('new','active','pause')),
 created_at timestamptz not null default now()
);
create table if not exists public.featured_videos (
 id uuid primary key default gen_random_uuid(),
 title text not null check(char_length(title) between 1 and 120),
 author text not null check(char_length(author) between 1 and 70),
 source_url text not null check(source_url ~ '^https://'),
 description text not null default '' check(char_length(description)<=500),
 allow_download boolean not null default false,
 created_at timestamptz not null default now()
);
create table if not exists public.chat_messages (
 id uuid primary key default gen_random_uuid(),
 author_id uuid not null references public.profiles(id) on delete cascade,
 body text not null check(char_length(trim(body)) between 1 and 1000),
 removed boolean not null default false,
 created_at timestamptz not null default now()
);
create table if not exists public.chat_reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null references public.profiles(id) on delete cascade,
 message_id uuid not null references public.chat_messages(id) on delete cascade,
 reason text not null check(char_length(reason) between 1 and 250),
 resolved boolean not null default false,
 created_at timestamptz not null default now(),
 unique(reporter_id,message_id)
);
create index if not exists idx_messages_recent on public.chat_messages(created_at desc);
create index if not exists idx_reports_open on public.chat_reports(resolved,created_at desc);

-- Create a profile for each new auth user, without exposing email address to others.
create or replace function public.new_user_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,display_name) values(new.id,'Участник_'||substring(new.id::text from 1 for 8)) on conflict do nothing;
 return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.new_user_profile();

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=(select auth.uid()) and role='admin');
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated,anon;

alter table public.profiles enable row level security;
alter table public.site_settings enable row level security;
alter table public.members enable row level security;
alter table public.featured_videos enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_reports enable row level security;

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to anon, authenticated using(true);
drop policy if exists profiles_self_edit on public.profiles;
-- No direct profile edits: roles must not be assigned by browser.

drop policy if exists settings_read on public.site_settings;
create policy settings_read on public.site_settings for select to anon,authenticated using(true);
drop policy if exists settings_admin_insert on public.site_settings;
create policy settings_admin_insert on public.site_settings for insert to authenticated with check(public.is_admin());
drop policy if exists settings_admin_update on public.site_settings;
create policy settings_admin_update on public.site_settings for update to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists members_read on public.members;
create policy members_read on public.members for select to anon,authenticated using(true);
drop policy if exists members_admin_insert on public.members;
create policy members_admin_insert on public.members for insert to authenticated with check(public.is_admin());
drop policy if exists members_admin_update on public.members;
create policy members_admin_update on public.members for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists members_admin_delete on public.members;
create policy members_admin_delete on public.members for delete to authenticated using(public.is_admin());

drop policy if exists featured_read on public.featured_videos;
create policy featured_read on public.featured_videos for select to anon,authenticated using(true);
drop policy if exists featured_admin_insert on public.featured_videos;
create policy featured_admin_insert on public.featured_videos for insert to authenticated with check(public.is_admin());
drop policy if exists featured_admin_update on public.featured_videos;
create policy featured_admin_update on public.featured_videos for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists featured_admin_delete on public.featured_videos;
create policy featured_admin_delete on public.featured_videos for delete to authenticated using(public.is_admin());

drop policy if exists messages_read on public.chat_messages;
create policy messages_read on public.chat_messages for select to anon,authenticated using(not removed or public.is_admin());
drop policy if exists messages_write on public.chat_messages;
create policy messages_write on public.chat_messages for insert to authenticated with check(author_id=(select auth.uid()) and not removed);
drop policy if exists messages_admin_update on public.chat_messages;
create policy messages_admin_update on public.chat_messages for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists messages_admin_delete on public.chat_messages;
create policy messages_admin_delete on public.chat_messages for delete to authenticated using(public.is_admin());

drop policy if exists reports_insert on public.chat_reports;
create policy reports_insert on public.chat_reports for insert to authenticated with check(reporter_id=(select auth.uid()) and not resolved);
drop policy if exists reports_select on public.chat_reports;
create policy reports_select on public.chat_reports for select to authenticated using(reporter_id=(select auth.uid()) or public.is_admin());
drop policy if exists reports_update on public.chat_reports;
create policy reports_update on public.chat_reports for update to authenticated using(public.is_admin()) with check(public.is_admin());

-- Server-side throttle: reject second chat message posted less than 5 seconds later.
create or replace function public.chat_rate_limit() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.chat_messages where author_id=new.author_id and created_at>now()-interval '5 seconds') then
  raise exception 'Подожди 5 секунд перед следующим сообщением';
 end if;
 return new;
end $$;
drop trigger if exists chat_throttle on public.chat_messages;
create trigger chat_throttle before insert on public.chat_messages for each row execute function public.chat_rate_limit();

-- Public banner bucket. Only admins may upload/update/delete files.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('banners','banners',true,5000000,array['image/png','image/jpeg'])
on conflict(id) do update set public=true,file_size_limit=5000000,allowed_mime_types=array['image/png','image/jpeg'];
drop policy if exists banner_public_read on storage.objects;
create policy banner_public_read on storage.objects for select to anon,authenticated using(bucket_id='banners');
drop policy if exists banner_admin_insert on storage.objects;
create policy banner_admin_insert on storage.objects for insert to authenticated with check(bucket_id='banners' and public.is_admin());
drop policy if exists banner_admin_update on storage.objects;
create policy banner_admin_update on storage.objects for update to authenticated using(bucket_id='banners' and public.is_admin()) with check(bucket_id='banners' and public.is_admin());
drop policy if exists banner_admin_delete on storage.objects;
create policy banner_admin_delete on storage.objects for delete to authenticated using(bucket_id='banners' and public.is_admin());

-- Enable realtime for chat (run once; ignore duplicate membership error when repeating):
do $$ begin alter publication supabase_realtime add table public.chat_messages;
exception when duplicate_object then null; end $$;

-- Grant first administrator ONLY in SQL editor, AFTER logging in once and creating profile:
-- update public.profiles set role='admin' where id='<UUID from Authentication > Users>';
-- Do not create public RPCs which elevate roles.


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
begin
 insert into public.admin_logs(actor_id,action,details)
 values((select auth.uid()),TG_TABLE_NAME||'.'||lower(TG_OP),
   jsonb_build_object('id',coalesce(to_jsonb(new)->>'id',to_jsonb(old)->>'id','main')));
 return coalesce(new,old);
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


-- Authored starter lessons. No fake sources or UI screenshots. All are editable by admins.
-- Re-running keeps existing edits (ON CONFLICT DO NOTHING).
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('a06bcd83-864d-085f-73b6-93b56d84f3c0','Основы','beginner','{"ru": "С чего начать монтаж", "en": "Editing basics", "uk": "Монтаж із нуля"}'::jsonb,'{"ru": "Собери первый законченный ролик без лишних эффектов.", "en": "Step-by-step tutorial about editing basics.", "uk": "Покроковий урок: монтаж із нуля."}'::jsonb,'{"ru": "1. Сначала определи, что зритель должен понять и почувствовать после ролика. Пример: неожиданная реакция на стриме.\n2. Найди начало события и короткую кульминацию. Не начинай с долгого приветствия.\n3. Создай проект 9:16 и перенеси исходный фрагмент на таймлайн.\n4. Обрежь паузы, добавь важный контекст только там, где он нужен.\n5. Проверь слышимость речи, контраст субтитров и кадрирование лица.\n6. Экспортируй пробную версию и покажи человеку, который не видел стрим. Если смысл непонятен, пересобери первые секунды.\nПрактика: сделай два варианта первых 2 секунд и сравни понятность.\nЧастые ошибки: перегруз эффектами, обрезанная концовка, слишком мелкий текст."}'::jsonb,10,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('efafb67b-f431-b1e7-3b21-4178378cc640','CapCut · Телефон','beginner','{"ru": "CapCut на телефоне — рабочий процесс", "en": "CapCut on mobile", "uk": "CapCut на телефоні"}'::jsonb,'{"ru": "От импорта записи до вертикального экспорта.", "en": "Step-by-step tutorial about capcut on mobile.", "uk": "Покроковий урок: capcut на телефоні."}'::jsonb,'{"ru": "1. Открой CapCut и создай новый проект. Выбери фрагмент из галереи.\n2. В разделе формата установи 9:16, осторожно перемести область кадрирования, сохрани лицо и действие.\n3. Выдели клип, используй «Разделить» (Split), чтобы удалить паузы и неудачные дубли.\n4. Через «Текст» добавь короткие субтитры. Автоматическое распознавание обязательно вычитай вручную.\n5. В разделе «Аудио» настрой громкость музыки ниже речи, добавь плавное появление и затухание.\n6. В экспорте выбери 1080p и FPS, соответствующий исходнику, затем проверь результат целиком.\nПрактика: создай 15-секундную нарезку с одной кульминацией.\nОшибка: чрезмерное масштабирование слабого исходника."}'::jsonb,20,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('3dc401ad-21d0-b51f-e762-61e18d68a9e7','CapCut · ПК','beginner','{"ru": "CapCut на ПК — монтаж с дорожками", "en": "CapCut on desktop", "uk": "CapCut на ПК"}'::jsonb,'{"ru": "Работа с клипами, звуком и текстом в настольной версии.", "en": "Step-by-step tutorial about capcut on desktop.", "uk": "Покроковий урок: capcut на пк."}'::jsonb,'{"ru": "1. Открой CapCut Desktop, создай проект и импортируй исходное видео.\n2. Перетащи запись на таймлайн. Помести речь и музыку на отдельные дорожки, чтобы их легче было балансировать.\n3. Используй разрезание и магнитное прилипание для точного удаления пауз.\n4. Через настройки видео отрегулируй кадрирование и ключевые кадры движения.\n5. Добавь субтитры, проверь расположение в безопасной зоне TikTok.\n6. Экспортируй H.264/MP4 и просмотри файл в обычном видеоплеере.\nПрактика: сравни динамику ролика до и после удаления всех лишних пауз.\nОшибка: оставлять музыку громче голоса."}'::jsonb,30,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('8704bfe5-a784-f692-8013-a45e791e170a','Premiere Pro','intermediate','{"ru": "Premiere Pro — базовый таймлайн", "en": "Premiere Pro basics", "uk": "Основи Premiere Pro"}'::jsonb,'{"ru": "Последовательности, дорожки, разрезы и экспорт.", "en": "Step-by-step tutorial about premiere pro basics.", "uk": "Покроковий урок: основи premiere pro."}'::jsonb,'{"ru": "1. Создай проект и импортируй видеоклипы через панель Project.\n2. Перетащи клип на Timeline и создай последовательность с параметрами, подходящими вертикальному формату.\n3. Используй Razor Tool (C) или Add Edit для разрезов, Selection Tool (V) для перестановки.\n4. Разложи речь, музыку и эффекты по отдельным аудиодорожкам.\n5. Добавь текст в Essential Graphics, настрой читаемость и безопасные поля.\n6. Через Export/Media выбери H.264 и подходящий вертикальный пресет; проверь итоговый рендер.\nПрактика: сделай одну монтажную сцену тремя разными ритмами.\nОшибка: менять частоту кадров без необходимости."}'::jsonb,40,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('3531f17a-945b-2222-723e-73dcfbfa6b0f','Нарезки стримов','beginner','{"ru": "Как нарезать стрим с понятным сюжетом", "en": "Stream clipping workflow", "uk": "Створення нарізок зі стримів"}'::jsonb,'{"ru": "Одна идея, быстрый контекст, кульминация и финал.", "en": "Step-by-step tutorial about stream clipping workflow.", "uk": "Покроковий урок: створення нарізок зі стримів."}'::jsonb,'{"ru": "1. Просматривай VOD с пометками сильных моментов: эмоции, неожиданные повороты, победы, ошибки.\n2. Для каждого момента сформулируй в одном предложении, что произошло и почему это интересно.\n3. Оставь только контекст, без которого зритель не поймёт событие.\n4. Покажи главное действие в первые секунды, затем при необходимости верни короткую предысторию.\n5. Не обрывай шутку или реакцию до логического завершения.\n6. Проверь, что источники и права на публикацию не нарушаются.\nПрактика: из пяти моментов отберите один понятный без знакомства со стримером.\nОшибка: длинное начало, понятное только постоянным зрителям."}'::jsonb,50,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('bf8771b1-977e-8de0-2d30-c69bb451050d','Сюжет','intermediate','{"ru": "Как выбрать лучший момент", "en": "Choosing strong moments", "uk": "Як обрати найкращий момент"}'::jsonb,'{"ru": "Критерии удержания, ясности и эмоционального эффекта.", "en": "Step-by-step tutorial about choosing strong moments.", "uk": "Покроковий урок: як обрати найкращий момент."}'::jsonb,'{"ru": "1. Оцени момент по трём вопросам: понятно ли действие, есть ли неожиданность, есть ли завершение.\n2. Разбей длинное событие на 10–25-секундные сюжетные единицы.\n3. Проверь, не приходится ли объяснять несколько минут контекста.\n4. Выбери первый кадр с действием или сильной реакцией.\n5. Посмотри версию без субтитров, затем добавь субтитры и сравни читаемость.\n6. Отложи ролик и пересмотри позднее без исходного контекста.\nПрактика: выбери два фрагмента одного стрима и обоснуй выбор по трём критериям.\nОшибка: путать громкий крик с интересным сюжетом."}'::jsonb,60,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('a50de50f-4e21-7ff3-59ed-a89d30b344f9','Таймлайн','intermediate','{"ru": "Ключевые кадры и плавное движение", "en": "Keyframes and motion", "uk": "Ключові кадри та рух"}'::jsonb,'{"ru": "Как анимировать масштаб и положение без дёрганья.", "en": "Step-by-step tutorial about keyframes and motion.", "uk": "Покроковий урок: ключові кадри та рух."}'::jsonb,'{"ru": "1. Помести курсор в точку начала движения, добавь ключевой кадр масштаба и позиции.\n2. Перемести курсор в конец, измени масштаб умеренно, чтобы не потерять качество.\n3. Используй easing/плавные кривые, когда это поддерживает текущая версия программы.\n4. Проверь, не выходит ли важный объект за пределы вертикального кадра.\n5. Избегай постоянного зума: движение должно акцентировать эмоцию или действие.\nПрактика: сделай мягкое увеличение на реакцию длительностью 0,4–0,8 секунды.\nОшибка: сильное приближение исходника низкого разрешения."}'::jsonb,70,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('9067f3ea-00a7-6f46-ad2e-3b1c7e52bbcf','Звук','intermediate','{"ru": "Чистый звук в нарезках", "en": "Clean audio and mixing", "uk": "Чистий звук та мікшування"}'::jsonb,'{"ru": "Разборчивый голос, музыкальный фон и плавные уровни.", "en": "Step-by-step tutorial about clean audio and mixing.", "uk": "Покроковий урок: чистий звук та мікшування."}'::jsonb,'{"ru": "1. Сначала прослушай голос без музыки в наушниках и на телефоне.\n2. Удали явные лишние паузы и проверь, нет ли обрезанных согласных на склейках.\n3. Отрегулируй громкость голоса, избегая цифрового клиппинга.\n4. Подложи музыку тише речи, а в моменты кульминации используй автоматизацию громкости.\n5. Добавь короткие fade-in/fade-out на стыках, чтобы не было щелчков.\n6. Переслушай итог на низкой громкости: если слова теряются, музыка слишком громкая.\nПрактика: сделай два микса одной сцены и выбери разборчивый.\nОшибка: агрессивное шумоподавление, делающее голос металлическим."}'::jsonb,80,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('58f41c33-6ce7-84cd-24ee-c225c1bd9e49','Эффекты','intermediate','{"ru": "Переходы и визуальные эффекты", "en": "Transitions and effects", "uk": "Переходи та ефекти"}'::jsonb,'{"ru": "Используй эффекты там, где они помогают смыслу.", "en": "Step-by-step tutorial about transitions and effects.", "uk": "Покроковий урок: переходи та ефекти."}'::jsonb,'{"ru": "1. Сначала собери нарезку обычными склейками. Если сюжет работает — база хорошая.\n2. Подбери переход по направлению движения объектов, а не по яркости эффекта.\n3. Для удара или крика протестируй короткий зум, стоп-кадр либо замедление.\n4. Не используй несколько тяжёлых эффектов подряд: они мешают восприятию.\n5. Проверяй границы переходов кадр за кадром на предмет чёрных вспышек.\n6. Убедись, что лицензия используемых эффектов и материалов разрешает публикацию.\nПрактика: сохрани вариант без эффектов и сравни удержание внимания в тестовом просмотре.\nОшибка: вставлять переходы только потому, что они трендовые."}'::jsonb,90,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('c53fd435-6f02-f59a-300a-5f579a1f9a02','Цвет','advanced','{"ru": "Цветокоррекция игрового видео", "en": "Color correction", "uk": "Корекція кольору"}'::jsonb,'{"ru": "Как улучшать контраст и насыщенность без потери деталей.", "en": "Step-by-step tutorial about color correction.", "uk": "Покроковий урок: корекція кольору."}'::jsonb,'{"ru": "1. Сравни уровень яркости исходного игрового ролика и веб-камеры.\n2. Исправь слишком тёмные и пересвеченные фрагменты до добавления стилистических фильтров.\n3. Подстрой цветовую температуру так, чтобы кожа на камере выглядела естественно.\n4. Умеренно увеличивай контраст; следи, чтобы интерфейс игры не стал нечитаемым.\n5. Проверь эффект на экране телефона при обычной яркости.\n6. Экспортируй короткий тестовый отрывок и сравни до/после.\nПрактика: выровняй два клипа, снятые с разным балансом белого.\nОшибка: чрезмерная насыщенность и резкость, создающая ореолы."}'::jsonb,100,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('7a76fea2-34d2-50f6-63a7-5cf5557fd876','Субтитры','beginner','{"ru": "Субтитры для вертикальных видео", "en": "Subtitles for vertical video", "uk": "Субтитри для вертикального відео"}'::jsonb,'{"ru": "Размер, контраст, расположение и ручная проверка.", "en": "Step-by-step tutorial about subtitles for vertical video.", "uk": "Покроковий урок: субтитри для вертикального відео."}'::jsonb,'{"ru": "1. Сначала получи текст речи (автоматически или вручную).\n2. Обязательно исправь ошибки распознавания имён, игрового сленга и английских терминов.\n3. Раздели текст на короткие смысловые группы; не выводи слишком много слов сразу.\n4. Установи шрифт, который читается на маленьком экране. Используй обводку или фон для контраста.\n5. Размести субтитры вне области системных кнопок и описания TikTok.\n6. Посмотри экспорт в реальном размере на телефоне.\nПрактика: проверь читаемость на яркой и тёмной сцене.\nОшибка: слишком мелкий текст и длинные строчки."}'::jsonb,110,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('6c150906-d718-a4b1-beec-38271d00718c','Экспорт','beginner','{"ru": "Правильный экспорт для TikTok и Shorts", "en": "Export for Shorts and TikTok", "uk": "Експорт для TikTok і Shorts"}'::jsonb,'{"ru": "Параметры файла, FPS, битрейт и финальная проверка.", "en": "Step-by-step tutorial about export for shorts and tiktok.", "uk": "Покроковий урок: експорт для tiktok і shorts."}'::jsonb,'{"ru": "1. Подготовь вертикальную последовательность с соотношением 9:16, обычно 1080×1920.\n2. Старайся сохранять частоту кадров, соответствующую исходнику: часто 30 или 60 FPS.\n3. Выбирай MP4/H.264 для широкой совместимости, если конкретная платформа не требует другого.\n4. Используй качественный экспорт без чрезмерно низкого битрейта.\n5. Проверь цвет, звук и финальный кадр уже в сохранённом файле.\n6. Перед публикацией убедись, что важные элементы не перекрываются интерфейсом приложения.\nПрактика: экспортируй один фрагмент с разным битрейтом и сравни качество/размер.\nОшибка: многократно перекодировать один и тот же файл."}'::jsonb,120,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('2ea10f2c-403f-41e1-9068-41ac62e659a0','Качество','intermediate','{"ru": "Как сохранить качество источника", "en": "Preserve video quality", "uk": "Збереження якості відео"}'::jsonb,'{"ru": "Разрешение, кодеки, повторная компрессия и безопасное масштабирование.", "en": "Step-by-step tutorial about preserve video quality.", "uk": "Покроковий урок: збереження якості відео."}'::jsonb,'{"ru": "1. Проверь разрешение и частоту кадров исходника до редактирования.\n2. Не ожидай, что апскейл 720p до 1080p восстановит потерянные детали.\n3. Если возможно, используй оригинальную запись, а не пересланную через мессенджер.\n4. Старайся избежать многоступенчатого повторного экспорта.\n5. Настрой подходящий битрейт для быстро движущихся игр.\n6. Сравни экспорт на динамичных сценах, где особенно видны артефакты сжатия.\nПрактика: выдели 5 секунд активного движения и используй их для тестов настроек.\nОшибка: агрессивная резкость и шумоподавление."}'::jsonb,130,true) on conflict(id) do nothing;
insert into public.lessons(id,category,difficulty,title_i18n,summary_i18n,content_i18n,sort_order,is_published) values('e761de21-d9d5-e0b8-6286-9037d1e20e59','Динамика','advanced','{"ru": "Динамика и ритм: монтаж без пауз", "en": "Editing rhythm and pacing", "uk": "Динаміка та ритм монтажу"}'::jsonb,'{"ru": "Как ускорить ролик без потери смысла.", "en": "Step-by-step tutorial about editing rhythm and pacing.", "uk": "Покроковий урок: динаміка та ритм монтажу."}'::jsonb,'{"ru": "1. Отметь в сценарии контекст, действие, реакцию и концовку.\n2. Удали паузы, в которых ничего не меняется, но оставь полезные паузы перед кульминацией.\n3. Сопоставь склейки с фразами и движением, а музыкальные акценты используй умеренно.\n4. Включи просмотр без звука, чтобы проверить визуальную логику. Затем прослушай отдельно аудио.\n5. Проверяй склейки на щелчки, внезапные скачки громкости и обрывки фраз.\n6. Сравни монтаж с 10% более короткой версией: иногда сжатие усиливает ролик, иногда уничтожает юмор.\nПрактика: проведи A/B-проверку двух вариантов начала у небольшой группы зрителей.\nОшибка: резать каждую секунду только ради активности кадра."}'::jsonb,140,true) on conflict(id) do nothing;
