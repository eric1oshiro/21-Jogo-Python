-- Esquema da tabela public.profiles aplicado no projeto Supabase "21 game".
-- A tabela guarda somente o apelido público; a senha permanece no Supabase Auth.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nickname text not null,
  created_at timestamptz not null default now(),
  constraint profiles_nickname_length check (char_length(nickname) between 3 and 20),
  constraint profiles_nickname_trimmed check (nickname = btrim(nickname))
);

create unique index if not exists profiles_nickname_case_insensitive_key
  on public.profiles (lower(nickname));

alter table public.profiles enable row level security;

revoke all on table public.profiles from anon;
grant select, insert, update on table public.profiles to authenticated;

drop policy if exists "Authenticated users can read player nicknames" on public.profiles;
create policy "Authenticated users can read player nicknames"
  on public.profiles for select to authenticated
  using (true);

drop policy if exists "Users can create their own profile" on public.profiles;
create policy "Users can create their own profile"
  on public.profiles for insert to authenticated
  with check ((select auth.uid()) = id);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);
