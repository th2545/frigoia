-- =====================================================================
-- Mon frigo : comptes + frigos partagés (Supabase)
-- Préfixe "frigo_" pour ne pas se mélanger avec d'autres projets.
-- =====================================================================

-- ---------- Profils (1 par compte) ----------
create table public.frigo_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Moi' check (char_length(display_name) between 1 and 40),
  appliances text[] not null default '{}',
  other_appliance text not null default '' check (char_length(other_appliance) <= 60),
  created_at timestamptz not null default now()
);

-- ---------- Frigos ----------
create or replace function public.frigo_gen_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; -- 31 caractères sans ambiguïté
  b bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  code text := '';
  i int;
begin
  for i in 0..7 loop
    code := code || substr(alphabet, (get_byte(b, i) % 31) + 1, 1);
  end loop;
  return code;
end $$;

create table public.frigo_fridges (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Mon frigo' check (char_length(name) between 1 and 40),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  invite_code text not null unique default public.frigo_gen_code(),
  created_at timestamptz not null default now()
);

create table public.frigo_members (
  fridge_id uuid not null references public.frigo_fridges(id) on delete cascade,
  user_id uuid not null references public.frigo_profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (fridge_id, user_id)
);
create index frigo_members_user_idx on public.frigo_members(user_id);

-- ---------- Produits du frigo (suppression "douce" pour garder les stats) ----------
create table public.frigo_items (
  fridge_id uuid not null references public.frigo_fridges(id) on delete cascade,
  id bigint not null,                              -- id généré par l'appli (Date.now())
  code text not null default '' check (char_length(code) <= 40),
  name text not null check (char_length(name) between 1 and 120),
  expiry_date date,
  added_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  removed_kind text check (removed_kind in ('eat', 'out')),
  removed_by uuid references auth.users(id) on delete set null,
  removed_at timestamptz,
  primary key (fridge_id, id)
);
create index frigo_items_active_idx on public.frigo_items(fridge_id) where removed_kind is null;

-- ---------- Mémoire code-barres -> nom ----------
create table public.frigo_product_names (
  fridge_id uuid not null references public.frigo_fridges(id) on delete cascade,
  code text not null check (char_length(code) between 1 and 40),
  name text not null check (char_length(name) between 1 and 120),
  primary key (fridge_id, code)
);

-- ---------- Liste de courses partagée ----------
create table public.frigo_shopping (
  fridge_id uuid not null references public.frigo_fridges(id) on delete cascade,
  id text not null check (char_length(id) <= 60),
  name text not null check (char_length(name) between 1 and 80),
  price numeric(8,2),
  checked boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (fridge_id, id)
);

-- ---------- Repas déjà faits (pour ne pas les reproposer) ----------
create table public.frigo_meals (
  id bigint generated always as identity primary key,
  fridge_id uuid not null references public.frigo_fridges(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  day date not null default current_date,
  created_by uuid default auth.uid() references auth.users(id) on delete set null
);
create index frigo_meals_idx on public.frigo_meals(fridge_id, day);

-- =====================================================================
-- Fonctions d'aide (security definer : évitent les boucles de RLS)
-- =====================================================================
create or replace function public.frigo_is_member(fid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.frigo_members m where m.fridge_id = fid and m.user_id = (select auth.uid()));
$$;

create or replace function public.frigo_is_owner(fid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.frigo_members m where m.fridge_id = fid and m.user_id = (select auth.uid()) and m.role = 'owner');
$$;

create or replace function public.frigo_shares_with(uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.frigo_members a
    join public.frigo_members b on a.fridge_id = b.fridge_id
    where a.user_id = (select auth.uid()) and b.user_id = uid
  );
$$;

-- Création automatique du profil à l'inscription
create or replace function public.frigo_handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.frigo_profiles (id, display_name)
  values (new.id, coalesce(nullif(left(trim(new.raw_user_meta_data->>'display_name'), 40), ''), split_part(new.email, '@', 1), 'Moi'))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger frigo_on_auth_user_created
  after insert on auth.users
  for each row execute function public.frigo_handle_new_user();

-- Le créateur d'un frigo en devient automatiquement propriétaire
create or replace function public.frigo_handle_new_fridge() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.frigo_members (fridge_id, user_id, role) values (new.id, new.owner_id, 'owner');
  return new;
end $$;

create trigger frigo_on_fridge_created
  after insert on public.frigo_fridges
  for each row execute function public.frigo_handle_new_fridge();

-- Créer un frigo (le déclencheur ajoute le créateur comme propriétaire)
create or replace function public.frigo_create(p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  insert into public.frigo_fridges (name, owner_id)
  values (coalesce(nullif(left(trim(p_name), 40), ''), 'Mon frigo'), (select auth.uid()))
  returning id into fid;
  return fid;
end $$;

-- Rejoindre un frigo avec un code d'invitation
create or replace function public.frigo_join(p_code text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare fid uuid;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  select id into fid from public.frigo_fridges where invite_code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if fid is null then raise exception 'code_not_found'; end if;
  insert into public.frigo_members (fridge_id, user_id, role) values (fid, (select auth.uid()), 'member') on conflict do nothing;
  return fid;
end $$;

-- Nouveau code d'invitation (propriétaire uniquement) : l'ancien code ne marche plus
create or replace function public.frigo_new_code(fid uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  if not public.frigo_is_owner(fid) then raise exception 'not_owner'; end if;
  c := public.frigo_gen_code();
  update public.frigo_fridges set invite_code = c where id = fid;
  return c;
end $$;

-- Le code d'invitation n'est lisible que par les membres (via la table, protégée par RLS)
revoke execute on function public.frigo_create(text) from public, anon;
grant execute on function public.frigo_create(text) to authenticated;
revoke execute on function public.frigo_join(text) from public, anon;
revoke execute on function public.frigo_new_code(uuid) from public, anon;
revoke execute on function public.frigo_gen_code() from public, anon, authenticated;
revoke execute on function public.frigo_handle_new_user() from public, anon, authenticated;
revoke execute on function public.frigo_handle_new_fridge() from public, anon, authenticated;
grant execute on function public.frigo_join(text) to authenticated;
grant execute on function public.frigo_new_code(uuid) to authenticated;
grant execute on function public.frigo_is_member(uuid) to authenticated;
grant execute on function public.frigo_is_owner(uuid) to authenticated;
grant execute on function public.frigo_shares_with(uuid) to authenticated;
revoke execute on function public.frigo_is_member(uuid) from public, anon;
revoke execute on function public.frigo_is_owner(uuid) from public, anon;
revoke execute on function public.frigo_shares_with(uuid) from public, anon;

-- =====================================================================
-- Sécurité : RLS (personne ne voit un frigo dont il n'est pas membre)
-- =====================================================================
alter table public.frigo_profiles enable row level security;
alter table public.frigo_fridges enable row level security;
alter table public.frigo_members enable row level security;
alter table public.frigo_items enable row level security;
alter table public.frigo_product_names enable row level security;
alter table public.frigo_shopping enable row level security;
alter table public.frigo_meals enable row level security;

-- Profils : le sien + ceux des personnes avec qui on partage un frigo
create policy "profil: lecture" on public.frigo_profiles for select to authenticated
  using (id = (select auth.uid()) or public.frigo_shares_with(id));
create policy "profil: modification" on public.frigo_profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Frigos
create policy "frigo: lecture membres" on public.frigo_fridges for select to authenticated
  using (public.frigo_is_member(id));
create policy "frigo: renommer (propriétaire)" on public.frigo_fridges for update to authenticated
  using (public.frigo_is_owner(id)) with check (public.frigo_is_owner(id));
create policy "frigo: supprimer (propriétaire)" on public.frigo_fridges for delete to authenticated
  using (public.frigo_is_owner(id));

-- Membres : on voit les membres de ses frigos ; on peut partir ; le propriétaire peut retirer quelqu'un
create policy "membres: lecture" on public.frigo_members for select to authenticated
  using (public.frigo_is_member(fridge_id));
create policy "membres: quitter ou retirer" on public.frigo_members for delete to authenticated
  using (user_id = (select auth.uid()) or public.frigo_is_owner(fridge_id));

-- Contenu du frigo : tous les membres lisent et écrivent
create policy "produits: tout (membres)" on public.frigo_items for all to authenticated
  using (public.frigo_is_member(fridge_id)) with check (public.frigo_is_member(fridge_id));
create policy "noms: tout (membres)" on public.frigo_product_names for all to authenticated
  using (public.frigo_is_member(fridge_id)) with check (public.frigo_is_member(fridge_id));
create policy "courses: tout (membres)" on public.frigo_shopping for all to authenticated
  using (public.frigo_is_member(fridge_id)) with check (public.frigo_is_member(fridge_id));
create policy "repas: tout (membres)" on public.frigo_meals for all to authenticated
  using (public.frigo_is_member(fridge_id)) with check (public.frigo_is_member(fridge_id));

-- Index sur les colonnes utilisées par les politiques / clés étrangères
create index if not exists frigo_fridges_owner_idx on public.frigo_fridges(owner_id);
create index if not exists frigo_items_added_by_idx on public.frigo_items(added_by);

-- =====================================================================
-- Temps réel : tout le monde voit les changements instantanément
-- =====================================================================
alter table public.frigo_shopping replica identity full;
alter table public.frigo_members replica identity full;
alter table public.frigo_product_names replica identity full;
alter publication supabase_realtime add table
  public.frigo_items, public.frigo_shopping, public.frigo_product_names, public.frigo_meals, public.frigo_members;

-- =====================================================================
-- Invitations par email (lien à usage unique, valable 7 jours)
-- =====================================================================
create table public.frigo_invites (
  id uuid primary key default gen_random_uuid(),
  fridge_id uuid not null references public.frigo_fridges(id) on delete cascade,
  email text not null check (char_length(email) between 3 and 254),
  token text not null unique default (replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  invited_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_by uuid references auth.users(id) on delete set null,
  accepted_at timestamptz
);
create index frigo_invites_fridge_idx on public.frigo_invites(fridge_id);
create index frigo_invites_invited_by_idx on public.frigo_invites(invited_by);
create index frigo_invites_accepted_by_idx on public.frigo_invites(accepted_by);
alter table public.frigo_invites enable row level security;
create policy "invitations: lecture membres" on public.frigo_invites for select to authenticated
  using (public.frigo_is_member(fridge_id));
create policy "invitations: création membres" on public.frigo_invites for insert to authenticated
  with check (public.frigo_is_member(fridge_id) and invited_by = (select auth.uid()));
create policy "invitations: annulation membres" on public.frigo_invites for delete to authenticated
  using (public.frigo_is_member(fridge_id));

create or replace function public.frigo_invite_info(p_token text) returns table(fridge_name text, inviter_name text)
language sql stable security definer set search_path = '' as $$
  select f.name, p.display_name
  from public.frigo_invites i
  join public.frigo_fridges f on f.id = i.fridge_id
  left join public.frigo_profiles p on p.id = i.invited_by
  where i.token = p_token and i.accepted_at is null and i.expires_at > now();
$$;

create or replace function public.frigo_accept_invite(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare inv public.frigo_invites;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  select * into inv from public.frigo_invites where token = p_token for update;
  if not found or inv.expires_at <= now() then raise exception 'invite_invalid'; end if;
  if inv.accepted_at is not null and inv.accepted_by is distinct from (select auth.uid()) then raise exception 'invite_invalid'; end if;
  insert into public.frigo_members (fridge_id, user_id, role) values (inv.fridge_id, (select auth.uid()), 'member') on conflict do nothing;
  update public.frigo_invites set accepted_by = (select auth.uid()), accepted_at = coalesce(accepted_at, now()) where id = inv.id;
  return inv.fridge_id;
end $$;

revoke execute on function public.frigo_invite_info(text) from public;
revoke execute on function public.frigo_accept_invite(text) from public, anon;
grant execute on function public.frigo_invite_info(text) to anon, authenticated;
grant execute on function public.frigo_accept_invite(text) to authenticated;

-- Dernier frigo utilisé : retrouvé automatiquement sur un nouvel appareil
alter table public.frigo_profiles add column last_fridge uuid references public.frigo_fridges(id) on delete set null;
create index frigo_profiles_last_fridge_idx on public.frigo_profiles(last_fridge);

-- =====================================================================
-- Quantités : plusieurs exemplaires d'un même produit
-- =====================================================================
alter table public.frigo_items add column qty integer not null default 1 check (qty between 1 and 99);

-- Consommer / jeter UNE unité (retire la ligne si c'était la dernière)
create or replace function public.frigo_consume(p_fridge uuid, p_id bigint, p_kind text) returns void
language plpgsql security invoker set search_path = '' as $$
declare it public.frigo_items;
begin
  if p_kind not in ('eat', 'out') then raise exception 'bad_kind'; end if;
  select * into it from public.frigo_items
   where fridge_id = p_fridge and id = p_id and removed_kind is null for update;
  if not found then return; end if;
  if it.qty > 1 then
    update public.frigo_items set qty = qty - 1 where fridge_id = p_fridge and id = p_id;
    insert into public.frigo_items (fridge_id, id, code, name, expiry_date, qty, added_by, removed_kind, removed_by, removed_at)
    values (p_fridge, (extract(epoch from clock_timestamp()) * 1000000)::bigint, it.code, it.name, it.expiry_date, 1,
            it.added_by, p_kind, (select auth.uid()), now());
  else
    update public.frigo_items
       set removed_kind = p_kind, removed_by = (select auth.uid()), removed_at = now()
     where fridge_id = p_fridge and id = p_id;
  end if;
end $$;

create or replace function public.frigo_stats(p_fridge uuid) returns table(eaten bigint, thrown bigint)
language sql stable security invoker set search_path = '' as $$
  select coalesce(sum(qty) filter (where removed_kind = 'eat'), 0)::bigint,
         coalesce(sum(qty) filter (where removed_kind = 'out'), 0)::bigint
  from public.frigo_items where fridge_id = p_fridge and removed_kind is not null;
$$;

revoke execute on function public.frigo_consume(uuid, bigint, text) from public, anon;
revoke execute on function public.frigo_stats(uuid) from public, anon;
grant execute on function public.frigo_consume(uuid, bigint, text) to authenticated;
grant execute on function public.frigo_stats(uuid) to authenticated;

-- =====================================================================
-- Notifications (résumé du matin) : déjà appliqué sur ton projet
-- La fonction d'envoi est l'Edge Function « frigo-notify » (voir frigo-notify.ts)
-- =====================================================================
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

alter table public.frigo_profiles add column notify_days smallint not null default 2 check (notify_days between 0 and 3);

create table public.frigo_push_subs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique check (char_length(endpoint) <= 1000),
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index frigo_push_subs_user_idx on public.frigo_push_subs(user_id);
alter table public.frigo_push_subs enable row level security;
create policy "push: lecture propre" on public.frigo_push_subs for select to authenticated
  using (user_id = (select auth.uid()));
create policy "push: suppression propre" on public.frigo_push_subs for delete to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.frigo_push_register(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  insert into public.frigo_push_subs (user_id, endpoint, p256dh, auth)
  values ((select auth.uid()), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;
revoke execute on function public.frigo_push_register(text, text, text) from public, anon;
grant execute on function public.frigo_push_register(text, text, text) to authenticated;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table private.frigo_config (
  id boolean primary key default true check (id),
  vapid_public text,
  vapid_private text,
  cron_secret text not null default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
);
alter table private.frigo_config enable row level security;
insert into private.frigo_config (id) values (true);

create or replace function public.frigo_push_config() returns table(vapid_public text, vapid_private text, cron_secret text)
language sql stable security definer set search_path = '' as $$
  select c.vapid_public, c.vapid_private, c.cron_secret from private.frigo_config c where c.id;
$$;
create or replace function public.frigo_push_set_keys(p_pub text, p_priv text) returns void
language sql security definer set search_path = '' as $$
  update private.frigo_config set vapid_public = p_pub, vapid_private = p_priv where id and vapid_public is null;
$$;
create or replace function public.frigo_push_digest() returns table(endpoint text, p256dh text, auth text, items jsonb)
language sql stable security definer set search_path = '' as $$
  with today as (select (now() at time zone 'Europe/Paris')::date as d),
  due as (
    select m.user_id, i.name, i.qty, (i.expiry_date - t.d) as days
    from public.frigo_items i
    join public.frigo_members m on m.fridge_id = i.fridge_id
    join public.frigo_profiles p on p.id = m.user_id
    cross join today t
    where i.removed_kind is null and i.expiry_date is not null
      and i.expiry_date <= t.d + p.notify_days
  ),
  per_user as (
    select user_id, jsonb_agg(jsonb_build_object('name', name, 'qty', qty, 'days', days) order by days, name) as items
    from due group by user_id
  )
  select s.endpoint, s.p256dh, s.auth, u.items
  from per_user u join public.frigo_push_subs s on s.user_id = u.user_id;
$$;
revoke execute on function public.frigo_push_config() from public, anon, authenticated;
revoke execute on function public.frigo_push_set_keys(text, text) from public, anon, authenticated;
revoke execute on function public.frigo_push_digest() from public, anon, authenticated;
grant execute on function public.frigo_push_config() to service_role;
grant execute on function public.frigo_push_set_keys(text, text) to service_role;
grant execute on function public.frigo_push_digest() to service_role;

-- Envoi tous les jours à 07:00 UTC (environ 8 h en France)
select cron.schedule('frigo-resume-du-matin', '0 7 * * *', $cron$
  select net.http_post(
    url := 'https://ivaswprggznpmjlkcxbe.supabase.co/functions/v1/frigo-notify',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', (select cron_secret from private.frigo_config where id)),
    body := '{"action":"digest"}'::jsonb,
    timeout_milliseconds := 30000
  );
$cron$);
