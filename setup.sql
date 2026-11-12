-- Friends Calendar: run this ONCE in Supabase -> SQL Editor -> New query -> Run.

-- 1. Profiles (display name shown on each event) -------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40)
);
alter table public.profiles enable row level security;

create policy "profiles readable by members" on public.profiles
  for select to authenticated using (true);
create policy "members insert own profile" on public.profiles
  for insert to authenticated with check (id = auth.uid());
create policy "members update own profile" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Auto-create a profile when you add a user (name defaults to the part before the @)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Profiles for users that already exist (safe to re-run)
insert into public.profiles (id, display_name)
select id, split_part(email, '@', 1) from auth.users
on conflict (id) do nothing;

-- 2. Events -------------------------------------------------------------------
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  event_date date not null,
  title text not null check (char_length(title) between 1 and 100),
  description text check (char_length(description) <= 500),
  category text not null default 'event' check (category in ('birthday', 'event')),
  repeats_yearly boolean not null default false,
  image_path text,
  created_by uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists events_date_idx on public.events (event_date);
alter table public.events enable row level security;

-- Everyone logged in can see all events; you can only change your own.
create policy "events readable by members" on public.events
  for select to authenticated using (true);
create policy "members add own events" on public.events
  for insert to authenticated with check (created_by = auth.uid());
create policy "members edit own events" on public.events
  for update to authenticated using (created_by = auth.uid()) with check (created_by = auth.uid());
create policy "members delete own events" on public.events
  for delete to authenticated using (created_by = auth.uid());

-- 3. Photo storage (max 2 MB each, images only) -------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('event-images', 'event-images', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "members upload to own folder" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'event-images' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "members delete own images" on storage.objects
  for delete to authenticated
  using (bucket_id = 'event-images' and (storage.foldername(name))[1] = auth.uid()::text);
