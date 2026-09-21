-- KMP Player: аккаунты и лента. Выполни целиком в Supabase → SQL Editor.

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 2 and 32),
  created_at timestamptz not null default now()
);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  text text not null check (char_length(text) between 1 and 600),
  track jsonb not null,                      -- {src, ref, title, artist, duration, peaks, cover}
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

-- профиль создаётся автоматически при регистрации
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- лента с автором и счётчиками
create or replace view public.posts_feed with (security_invoker = on) as
select p.*, pr.name as author,
  (select count(*) from public.post_likes l where l.post_id = p.id)::int as likes,
  (select count(*) from public.comments c where c.post_id = p.id)::int as comments_count
from public.posts p join public.profiles pr on pr.id = p.user_id;

-- правила доступа: читать могут все, писать и удалять только своё
alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.comments enable row level security;

create policy "profiles read" on public.profiles for select using (true);
create policy "profiles update own" on public.profiles for update using (auth.uid() = id);

create policy "posts read" on public.posts for select using (true);
create policy "posts insert own" on public.posts for insert with check (auth.uid() = user_id);
create policy "posts delete own" on public.posts for delete using (auth.uid() = user_id);

create policy "likes read" on public.post_likes for select using (true);
create policy "likes insert own" on public.post_likes for insert with check (auth.uid() = user_id);
create policy "likes delete own" on public.post_likes for delete using (auth.uid() = user_id);

create policy "comments read" on public.comments for select using (true);
create policy "comments insert own" on public.comments for insert with check (auth.uid() = user_id);
create policy "comments delete own" on public.comments for delete using (auth.uid() = user_id);

grant select on public.posts_feed to anon, authenticated;
