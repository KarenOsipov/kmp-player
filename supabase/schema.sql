-- KMP Player: аккаунты, профили, облачная библиотека, лента.
-- Выполни ЦЕЛИКОМ в Supabase → SQL Editor → Run. Скрипт можно запускать повторно.

-- ================= профили =================
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 2 and 32),
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists bio text not null default '';
do $$ begin
  alter table public.profiles add constraint profiles_username_format check (username is null or username ~ '^[a-z0-9_.]{3,24}$');
exception when duplicate_object then null; end $$;
create unique index if not exists profiles_username_key on public.profiles (lower(username)) where username is not null;
do $$ begin
  alter table public.profiles add constraint profiles_bio_len check (char_length(bio) <= 160);
exception when duplicate_object then null; end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare n text := coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1));
begin
  n := left(n, 32);
  if char_length(n) < 2 then n := rpad(n, 2, '_'); end if;
  insert into public.profiles (id, name) values (new.id, n) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ================= облачная библиотека =================
create table if not exists public.tracks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  id text not null,
  kind text not null default 'file' check (kind in ('file', 'audius')),
  title text not null,
  artist text not null default '',
  album text not null default '',
  duration real,
  peaks jsonb,
  gain real,
  path text,                      -- путь в bucket tracks: <user_id>/<id>.<ext>
  cover text,                     -- маленькая обложка (data URL до ~40 КБ) или ссылка
  net jsonb,                      -- для онлайн-треков Audius
  size bigint not null default 0,
  ext text,
  created_at timestamptz not null default now(),
  primary key (user_id, id)
);

-- лайки, плейлисты, пресеты, счётчики прослушиваний (один документ на пользователя)
create table if not exists public.user_data (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- ================= лента =================
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  text text not null check (char_length(text) between 1 and 600),
  track jsonb not null,
  moment_start real check (moment_start >= 0),
  moment_end real check (moment_end > moment_start and moment_end - moment_start <= 60),
  mood text check (char_length(mood) <= 24),
  created_at timestamptz not null default now()
);
create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_user_idx on public.posts (user_id);

create table if not exists public.post_likes (
  post_id uuid references public.posts on delete cascade,
  user_id uuid references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  text text not null check (char_length(text) between 1 and 400),
  created_at timestamptz not null default now()
);
create index if not exists comments_post_idx on public.comments (post_id, created_at);

drop view if exists public.posts_feed;
create view public.posts_feed with (security_invoker = on) as
select p.*, pr.name as author, pr.avatar_url, pr.username,
  (select count(*) from public.post_likes l where l.post_id = p.id)::int as likes,
  (select count(*) from public.comments c where c.post_id = p.id)::int as comments_count
from public.posts p join public.profiles pr on pr.id = p.user_id;
grant select on public.posts_feed to anon, authenticated;

-- ================= правила доступа (RLS) =================
alter table public.profiles enable row level security;
alter table public.tracks enable row level security;
alter table public.user_data enable row level security;
alter table public.posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.comments enable row level security;

drop policy if exists "profiles read" on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles read" on public.profiles for select using (true);
create policy "profiles update own" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

drop policy if exists "tracks own" on public.tracks;
create policy "tracks own" on public.tracks for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "user_data own" on public.user_data;
create policy "user_data own" on public.user_data for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "posts read" on public.posts;
drop policy if exists "posts insert own" on public.posts;
drop policy if exists "posts delete own" on public.posts;
create policy "posts read" on public.posts for select using (true);
create policy "posts insert own" on public.posts for insert with check (auth.uid() = user_id);
create policy "posts delete own" on public.posts for delete using (auth.uid() = user_id);

drop policy if exists "likes read" on public.post_likes;
drop policy if exists "likes insert own" on public.post_likes;
drop policy if exists "likes delete own" on public.post_likes;
create policy "likes read" on public.post_likes for select using (true);
create policy "likes insert own" on public.post_likes for insert with check (auth.uid() = user_id);
create policy "likes delete own" on public.post_likes for delete using (auth.uid() = user_id);

drop policy if exists "comments read" on public.comments;
drop policy if exists "comments insert own" on public.comments;
drop policy if exists "comments delete own" on public.comments;
create policy "comments read" on public.comments for select using (true);
create policy "comments insert own" on public.comments for insert with check (auth.uid() = user_id);
create policy "comments delete own" on public.comments for delete using (auth.uid() = user_id);

-- ================= хранилище файлов =================
-- tracks: приватно, до 50 МБ на файл (лимит бесплатного тарифа); avatars: публично, до 2 МБ
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tracks', 'tracks', false, 52428800, array['audio/*', 'application/octet-stream'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "kmp tracks read own" on storage.objects;
drop policy if exists "kmp tracks insert own" on storage.objects;
drop policy if exists "kmp tracks update own" on storage.objects;
drop policy if exists "kmp tracks delete own" on storage.objects;
create policy "kmp tracks read own" on storage.objects for select to authenticated using (bucket_id = 'tracks' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "kmp tracks insert own" on storage.objects for insert to authenticated with check (bucket_id = 'tracks' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "kmp tracks update own" on storage.objects for update to authenticated using (bucket_id = 'tracks' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "kmp tracks delete own" on storage.objects for delete to authenticated using (bucket_id = 'tracks' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "kmp avatars read" on storage.objects;
drop policy if exists "kmp avatars insert own" on storage.objects;
drop policy if exists "kmp avatars update own" on storage.objects;
drop policy if exists "kmp avatars delete own" on storage.objects;
create policy "kmp avatars read" on storage.objects for select using (bucket_id = 'avatars');
create policy "kmp avatars insert own" on storage.objects for insert to authenticated with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "kmp avatars update own" on storage.objects for update to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "kmp avatars delete own" on storage.objects for delete to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ================= удаление аккаунта =================
-- Файлы приложение удаляет само через Storage API, потом вызывает эту функцию.
-- Удаление пользователя каскадно чистит профиль, треки, данные, посты, лайки и комментарии.
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
