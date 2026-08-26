-- ============================================================================
-- DOMUS — Migración inicial: perfiles, hogares, membresías, invitaciones
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Es seguro volver a ejecutar (usa IF NOT EXISTS / DROP ... IF EXISTS).
-- ============================================================================

-- Extensión para generar UUIDs
create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. TABLAS
-- ----------------------------------------------------------------------------

-- Perfiles públicos, uno por usuario de auth.users
create table if not exists public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  email           text not null,
  nombre_completo text,
  avatar_url      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- Hogares
create table if not exists public.hogares (
  id                  uuid primary key default gen_random_uuid(),
  nombre              text not null,
  descripcion         text,
  presupuesto_mensual numeric(12,2) not null default 0,
  creado_por          uuid not null references public.profiles(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Miembros de cada hogar (tabla puente usuario <-> hogar, con rol)
create table if not exists public.hogar_miembros (
  id          uuid primary key default gen_random_uuid(),
  hogar_id    uuid not null references public.hogares(id) on delete cascade,
  usuario_id  uuid not null references public.profiles(id) on delete cascade,
  rol         text not null default 'miembro' check (rol in ('administrador', 'miembro', 'invitado')),
  unido_en    timestamptz not null default now(),
  unique (hogar_id, usuario_id)
);

-- Invitaciones pendientes por correo (el invitado puede no estar registrado aún)
create table if not exists public.invitaciones (
  id            uuid primary key default gen_random_uuid(),
  hogar_id      uuid not null references public.hogares(id) on delete cascade,
  email         text not null,
  rol           text not null default 'miembro' check (rol in ('administrador', 'miembro', 'invitado')),
  invitado_por  uuid not null references public.profiles(id),
  estado        text not null default 'pendiente' check (estado in ('pendiente', 'aceptada', 'rechazada', 'expirada')),
  created_at    timestamptz not null default now(),
  expira_en     timestamptz not null default (now() + interval '7 days')
);

create index if not exists idx_hogar_miembros_usuario on public.hogar_miembros (usuario_id);
create index if not exists idx_hogar_miembros_hogar on public.hogar_miembros (hogar_id);
create index if not exists idx_invitaciones_email on public.invitaciones (lower(email));

-- ----------------------------------------------------------------------------
-- 2. FUNCIONES AUXILIARES (SECURITY DEFINER → evitan recursión en RLS)
-- ----------------------------------------------------------------------------

-- Reusable: actualiza updated_at automáticamente
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_hogares_updated_at on public.hogares;
create trigger trg_hogares_updated_at
  before update on public.hogares
  for each row execute function public.set_updated_at();

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ¿El usuario autenticado pertenece a este hogar?
create or replace function public.is_hogar_member(p_hogar_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.hogar_miembros
    where hogar_id = p_hogar_id and usuario_id = auth.uid()
  );
$$;

-- ¿El usuario autenticado es administrador de este hogar?
create or replace function public.is_hogar_admin(p_hogar_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.hogar_miembros
    where hogar_id = p_hogar_id and usuario_id = auth.uid() and rol = 'administrador'
  );
$$;

-- ¿Los usuarios A y B comparten al menos un hogar? (para poder verse los perfiles)
create or replace function public.comparte_hogar_con(p_usuario_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.hogar_miembros hm1
    join public.hogar_miembros hm2 on hm1.hogar_id = hm2.hogar_id
    where hm1.usuario_id = auth.uid() and hm2.usuario_id = p_usuario_id
  );
$$;

-- Al crear un hogar, el creador queda automáticamente como administrador
create or replace function public.handle_new_hogar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.hogar_miembros (hogar_id, usuario_id, rol)
  values (new.id, new.creado_por, 'administrador')
  on conflict (hogar_id, usuario_id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_handle_new_hogar on public.hogares;
create trigger trg_handle_new_hogar
  after insert on public.hogares
  for each row execute function public.handle_new_hogar();

-- Al registrarse un usuario nuevo: crea su perfil y acepta invitaciones pendientes
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, nombre_completo)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'nombre_completo', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;

  -- Acepta automáticamente cualquier invitación pendiente que coincida con su correo
  insert into public.hogar_miembros (hogar_id, usuario_id, rol)
  select i.hogar_id, new.id, i.rol
  from public.invitaciones i
  where lower(i.email) = lower(new.email)
    and i.estado = 'pendiente'
    and i.expira_en > now()
  on conflict (hogar_id, usuario_id) do nothing;

  update public.invitaciones
  set estado = 'aceptada'
  where lower(email) = lower(new.email)
    and estado = 'pendiente'
    and expira_en > now();

  return new;
end;
$$;

drop trigger if exists trg_handle_new_user on auth.users;
create trigger trg_handle_new_user
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Invitar a un miembro por correo: si ya tiene cuenta lo agrega directo al hogar,
-- si no, deja la invitación pendiente para cuando se registre (ver handle_new_user).
-- Se usa vía RPC desde el cliente en lugar de INSERT directo, porque el admin no
-- puede "ver" el perfil de alguien con quien todavía no comparte hogar (RLS).
create or replace function public.invitar_miembro(p_hogar_id uuid, p_email text, p_rol text default 'miembro')
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario_id uuid;
  v_resultado  text;
begin
  if not public.is_hogar_admin(p_hogar_id) then
    raise exception 'Solo un administrador del hogar puede invitar miembros';
  end if;

  if p_rol not in ('administrador', 'miembro', 'invitado') then
    raise exception 'Rol inválido: %', p_rol;
  end if;

  select id into v_usuario_id from public.profiles where lower(email) = lower(p_email);

  if v_usuario_id is not null then
    insert into public.hogar_miembros (hogar_id, usuario_id, rol)
    values (p_hogar_id, v_usuario_id, p_rol)
    on conflict (hogar_id, usuario_id) do update set rol = excluded.rol;

    insert into public.invitaciones (hogar_id, email, rol, invitado_por, estado)
    values (p_hogar_id, p_email, p_rol, auth.uid(), 'aceptada');

    v_resultado := 'agregado_directamente';
  else
    insert into public.invitaciones (hogar_id, email, rol, invitado_por, estado)
    values (p_hogar_id, p_email, p_rol, auth.uid(), 'pendiente');

    v_resultado := 'invitacion_pendiente';
  end if;

  return v_resultado;
end;
$$;

revoke execute on function public.invitar_miembro(uuid, text, text) from public;
grant execute on function public.invitar_miembro(uuid, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY
-- ----------------------------------------------------------------------------

alter table public.profiles       enable row level security;
alter table public.hogares        enable row level security;
alter table public.hogar_miembros enable row level security;
alter table public.invitaciones   enable row level security;

-- PROFILES ------------------------------------------------------------------
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles
  for select using (
    id = auth.uid() or public.comparte_hogar_con(id)
  );

drop policy if exists "profiles_update_propio" on public.profiles;
create policy "profiles_update_propio" on public.profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());

-- HOGARES ---------------------------------------------------------------------
-- Nota: además de is_hogar_member(), se permite ver el hogar si uno mismo es
-- quien lo creó. Esto evita un problema de "carrera" con RLS + RETURNING justo
-- al crear el hogar (la membresía la agrega un trigger AFTER INSERT y, sin esta
-- condición extra, el INSERT ... RETURNING del propio creador puede fallar).
drop policy if exists "hogares_select" on public.hogares;
create policy "hogares_select" on public.hogares
  for select using (public.is_hogar_member(id) or creado_por = auth.uid());

drop policy if exists "hogares_insert" on public.hogares;
create policy "hogares_insert" on public.hogares
  for insert with check (creado_por = auth.uid());

drop policy if exists "hogares_update" on public.hogares;
create policy "hogares_update" on public.hogares
  for update using (public.is_hogar_admin(id))
  with check (public.is_hogar_admin(id));

drop policy if exists "hogares_delete" on public.hogares;
create policy "hogares_delete" on public.hogares
  for delete using (public.is_hogar_admin(id));

-- HOGAR_MIEMBROS --------------------------------------------------------------
drop policy if exists "hogar_miembros_select" on public.hogar_miembros;
create policy "hogar_miembros_select" on public.hogar_miembros
  for select using (public.is_hogar_member(hogar_id));

drop policy if exists "hogar_miembros_insert" on public.hogar_miembros;
create policy "hogar_miembros_insert" on public.hogar_miembros
  for insert with check (public.is_hogar_admin(hogar_id));

drop policy if exists "hogar_miembros_update" on public.hogar_miembros;
create policy "hogar_miembros_update" on public.hogar_miembros
  for update using (public.is_hogar_admin(hogar_id))
  with check (public.is_hogar_admin(hogar_id));

drop policy if exists "hogar_miembros_delete" on public.hogar_miembros;
create policy "hogar_miembros_delete" on public.hogar_miembros
  for delete using (
    public.is_hogar_admin(hogar_id) or usuario_id = auth.uid()
  );

-- INVITACIONES ------------------------------------------------------------------
drop policy if exists "invitaciones_select" on public.invitaciones;
create policy "invitaciones_select" on public.invitaciones
  for select using (
    public.is_hogar_admin(hogar_id)
    or lower(email) = lower((select email from public.profiles where id = auth.uid()))
  );

drop policy if exists "invitaciones_insert" on public.invitaciones;
create policy "invitaciones_insert" on public.invitaciones
  for insert with check (public.is_hogar_admin(hogar_id));

drop policy if exists "invitaciones_update" on public.invitaciones;
create policy "invitaciones_update" on public.invitaciones
  for update using (
    public.is_hogar_admin(hogar_id)
    or lower(email) = lower((select email from public.profiles where id = auth.uid()))
  );

drop policy if exists "invitaciones_delete" on public.invitaciones;
create policy "invitaciones_delete" on public.invitaciones
  for delete using (public.is_hogar_admin(hogar_id));

-- ============================================================================
-- Fin de la migración inicial.
-- Próximos módulos (mercado, gastos, presupuesto, servicios, calendario)
-- se agregarán en archivos 002_*.sql, 003_*.sql, etc., siguiendo el mismo
-- patrón: tabla -> índices -> RLS por hogar_id usando is_hogar_member().
-- ============================================================================
