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
