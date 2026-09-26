-- ============================================================================
-- DOMUS — Migración 012: métodos de pago personales (billetera)
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql, sql/002_mercado.sql,
-- sql/003_gastos.sql, sql/004_servicios.sql, sql/008 y sql/011.
-- Es seguro volver a ejecutar (usa IF NOT EXISTS / DROP ... IF EXISTS).
--
-- Qué agrega:
-- Un método de pago (Efectivo, Nequi, Nu Bank, etc.) es 100% personal — no
-- tiene nada que ver con el hogar activo, cada quien crea y ve solo los suyos.
-- Cada método tiene un saldo que se ajusta solo:
--   - Se registra un gasto/compra/servicio "pagado" con ese método -> descuenta.
--   - Se edita/reabre/borra ese registro -> el descuento se revierte y, si
--     aplica, se vuelve a aplicar con los datos nuevos.
--   - Se registra un ingreso manual -> aumenta.
--   - Se transfiere entre dos métodos propios -> resta de uno, suma al otro.
-- Todo movimiento (menos la creación del método) queda en el historial
-- metodo_pago_movimientos. El saldo puede quedar negativo (sin bloqueos).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TABLAS
-- ----------------------------------------------------------------------------

create table if not exists public.metodos_pago (
  id          uuid primary key default gen_random_uuid(),
  usuario_id  uuid not null references public.profiles(id) on delete cascade,
  nombre      text not null check (length(trim(nombre)) > 0),
  saldo       numeric(12,2) not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (usuario_id, nombre)
);

create index if not exists idx_metodos_pago_usuario on public.metodos_pago (usuario_id);

drop trigger if exists trg_metodos_pago_updated_at on public.metodos_pago;
create trigger trg_metodos_pago_updated_at
  before update on public.metodos_pago
  for each row execute function public.set_updated_at();

create table if not exists public.metodo_pago_movimientos (
  id                uuid primary key default gen_random_uuid(),
  metodo_pago_id    uuid not null references public.metodos_pago(id) on delete cascade,
  usuario_id        uuid not null references public.profiles(id),
  tipo              text not null check (tipo in (
                      'ingreso', 'gasto', 'transferencia_salida', 'transferencia_entrada'
                    )),
  -- Siempre positivo; el signo lo determina "tipo" (ingreso/entrada suman,
  -- gasto/salida restan) — así el historial se lee igual de claro en ambos casos.
  monto             numeric(12,2) not null check (monto > 0),
  descripcion       text,
  -- Solo uno de estos tres queda lleno, según de qué módulo vino el gasto que
  -- generó el movimiento (null si es un ingreso o transferencia manual).
  gasto_id          uuid references public.gastos(id) on delete set null,
  item_mercado_id   uuid references public.mercado_items(id) on delete set null,
  servicio_id       uuid references public.servicios_pagos(id) on delete set null,
  -- Comparten este id las dos filas (salida + entrada) de una misma transferencia.
  transferencia_id  uuid,
  created_at        timestamptz not null default now()
);

create index if not exists idx_metodo_pago_movimientos_metodo on public.metodo_pago_movimientos (metodo_pago_id, created_at desc);
create index if not exists idx_metodo_pago_movimientos_usuario on public.metodo_pago_movimientos (usuario_id, created_at desc);
create index if not exists idx_metodo_pago_movimientos_gasto on public.metodo_pago_movimientos (gasto_id);
create index if not exists idx_metodo_pago_movimientos_item on public.metodo_pago_movimientos (item_mercado_id);
create index if not exists idx_metodo_pago_movimientos_servicio on public.metodo_pago_movimientos (servicio_id);

-- ----------------------------------------------------------------------------
-- 2. COLUMNAS NUEVAS: enlazan cada gasto/compra/servicio (y sus plantillas
--    recurrentes) con el método de pago personal usado.
-- ----------------------------------------------------------------------------

alter table public.gastos
  add column if not exists metodo_pago_id uuid references public.metodos_pago(id) on delete set null;
alter table public.gastos_recurrentes
  add column if not exists metodo_pago_id uuid references public.metodos_pago(id) on delete set null;

alter table public.mercado_items
  add column if not exists metodo_pago_id uuid references public.metodos_pago(id) on delete set null;

alter table public.servicios_pagos
  add column if not exists metodo_pago_id uuid references public.metodos_pago(id) on delete set null;
alter table public.servicios_recurrentes
  add column if not exists metodo_pago_id uuid references public.metodos_pago(id) on delete set null;

-- ----------------------------------------------------------------------------
-- 3. TRIGGERS: mantienen el saldo y el historial sincronizados solos.
--    security definer porque un gasto/compra/servicio del HOGAR lo puede
--    editar cualquier miembro, no solo el dueño del método de pago usado —
--    el ajuste de saldo debe aplicar igual sin depender de quién hizo click.
-- ----------------------------------------------------------------------------

create or replace function public.sync_metodo_pago_gastos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if old.estado = 'pagado' and old.metodo_pago_id is not null then
      update public.metodos_pago set saldo = saldo + old.monto where id = old.metodo_pago_id;
      delete from public.metodo_pago_movimientos where gasto_id = old.id;
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    if new.estado = 'pagado' and new.metodo_pago_id is not null then
      update public.metodos_pago set saldo = saldo - new.monto where id = new.metodo_pago_id;
      insert into public.metodo_pago_movimientos (metodo_pago_id, usuario_id, tipo, monto, descripcion, gasto_id)
      values (new.metodo_pago_id, new.registrado_por, 'gasto', new.monto, new.descripcion, new.id);
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_gastos_sync_metodo_pago on public.gastos;
create trigger trg_gastos_sync_metodo_pago
  after insert or update or delete on public.gastos
  for each row execute function public.sync_metodo_pago_gastos();

create or replace function public.sync_metodo_pago_mercado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_monto_old numeric(12,2);
  v_monto_new numeric(12,2);
begin
  if tg_op in ('UPDATE', 'DELETE') then
    v_monto_old := coalesce(old.precio_final, old.precio_estimado);
    if old.estado = 'comprado' and old.metodo_pago_id is not null and v_monto_old is not null and v_monto_old > 0 then
      update public.metodos_pago set saldo = saldo + v_monto_old where id = old.metodo_pago_id;
      delete from public.metodo_pago_movimientos where item_mercado_id = old.id;
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    v_monto_new := coalesce(new.precio_final, new.precio_estimado);
    if new.estado = 'comprado' and new.metodo_pago_id is not null and v_monto_new is not null and v_monto_new > 0 then
      update public.metodos_pago set saldo = saldo - v_monto_new where id = new.metodo_pago_id;
      insert into public.metodo_pago_movimientos (metodo_pago_id, usuario_id, tipo, monto, descripcion, item_mercado_id)
      values (new.metodo_pago_id, coalesce(new.comprado_por, new.agregado_por), 'gasto', v_monto_new, new.nombre, new.id);
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_mercado_sync_metodo_pago on public.mercado_items;
create trigger trg_mercado_sync_metodo_pago
  after insert or update or delete on public.mercado_items
  for each row execute function public.sync_metodo_pago_mercado();

create or replace function public.sync_metodo_pago_servicios()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if old.estado = 'pagado' and old.metodo_pago_id is not null then
      update public.metodos_pago set saldo = saldo + old.monto where id = old.metodo_pago_id;
      delete from public.metodo_pago_movimientos where servicio_id = old.id;
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    if new.estado = 'pagado' and new.metodo_pago_id is not null then
      update public.metodos_pago set saldo = saldo - new.monto where id = new.metodo_pago_id;
      insert into public.metodo_pago_movimientos (metodo_pago_id, usuario_id, tipo, monto, descripcion, servicio_id)
      values (new.metodo_pago_id, coalesce(new.pagado_por, new.registrado_por), 'gasto', new.monto, new.nombre, new.id);
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_servicios_sync_metodo_pago on public.servicios_pagos;
create trigger trg_servicios_sync_metodo_pago
  after insert or update or delete on public.servicios_pagos
  for each row execute function public.sync_metodo_pago_servicios();

-- ----------------------------------------------------------------------------
-- 4. FUNCIONES RPC: ingreso manual y transferencia entre métodos propios.
--    security definer porque insertan en metodo_pago_movimientos, que no
--    tiene policy de insert directa (solo se escribe desde aquí y desde los
--    triggers) — la seguridad real la dan los "usuario_id = auth.uid()" de
--    cada UPDATE de abajo, que si no matchean lanzan la excepción.
-- ----------------------------------------------------------------------------

create or replace function public.registrar_ingreso_metodo(p_metodo_id uuid, p_monto numeric, p_descripcion text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto debe ser mayor a cero';
  end if;

  update public.metodos_pago set saldo = saldo + p_monto
  where id = p_metodo_id and usuario_id = auth.uid();
  if not found then
    raise exception 'Método de pago no encontrado';
  end if;

  insert into public.metodo_pago_movimientos (metodo_pago_id, usuario_id, tipo, monto, descripcion)
  values (p_metodo_id, auth.uid(), 'ingreso', p_monto, p_descripcion);
end;
$$;

revoke execute on function public.registrar_ingreso_metodo(uuid, numeric, text) from public;
grant execute on function public.registrar_ingreso_metodo(uuid, numeric, text) to authenticated;

create or replace function public.transferir_entre_metodos(p_origen_id uuid, p_destino_id uuid, p_monto numeric, p_descripcion text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transferencia_id uuid := gen_random_uuid();
begin
  if p_monto is null or p_monto <= 0 then
    raise exception 'El monto debe ser mayor a cero';
  end if;
  if p_origen_id = p_destino_id then
    raise exception 'Elige dos métodos distintos';
  end if;

  update public.metodos_pago set saldo = saldo - p_monto
  where id = p_origen_id and usuario_id = auth.uid();
  if not found then
    raise exception 'Método de origen no encontrado';
  end if;

  update public.metodos_pago set saldo = saldo + p_monto
  where id = p_destino_id and usuario_id = auth.uid();
  if not found then
    raise exception 'Método de destino no encontrado';
  end if;

  insert into public.metodo_pago_movimientos (metodo_pago_id, usuario_id, tipo, monto, descripcion, transferencia_id)
  values (p_origen_id, auth.uid(), 'transferencia_salida', p_monto, p_descripcion, v_transferencia_id);

  insert into public.metodo_pago_movimientos (metodo_pago_id, usuario_id, tipo, monto, descripcion, transferencia_id)
  values (p_destino_id, auth.uid(), 'transferencia_entrada', p_monto, p_descripcion, v_transferencia_id);
end;
$$;

revoke execute on function public.transferir_entre_metodos(uuid, uuid, numeric, text) from public;
grant execute on function public.transferir_entre_metodos(uuid, uuid, numeric, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY: 100% privado, sin ninguna noción de hogar.
-- ----------------------------------------------------------------------------

alter table public.metodos_pago enable row level security;

drop policy if exists "metodos_pago_select" on public.metodos_pago;
create policy "metodos_pago_select" on public.metodos_pago
  for select using (usuario_id = auth.uid());

drop policy if exists "metodos_pago_insert" on public.metodos_pago;
create policy "metodos_pago_insert" on public.metodos_pago
  for insert with check (usuario_id = auth.uid());

drop policy if exists "metodos_pago_update" on public.metodos_pago;
create policy "metodos_pago_update" on public.metodos_pago
  for update using (usuario_id = auth.uid())
  with check (usuario_id = auth.uid());

drop policy if exists "metodos_pago_delete" on public.metodos_pago;
create policy "metodos_pago_delete" on public.metodos_pago
  for delete using (usuario_id = auth.uid());

alter table public.metodo_pago_movimientos enable row level security;

drop policy if exists "metodo_pago_movimientos_select" on public.metodo_pago_movimientos;
create policy "metodo_pago_movimientos_select" on public.metodo_pago_movimientos
  for select using (usuario_id = auth.uid());

-- Insert/update/delete de movimientos NO se exponen al cliente: solo los
-- generan los triggers (security definer) y las funciones RPC de arriba.

-- ----------------------------------------------------------------------------
-- 6. Método "Efectivo" por defecto: uno para cada usuario ya existente, y de
--    ahí en adelante uno automático para cada usuario nuevo (extiende
--    handle_new_user de sql/001_init.sql).
-- ----------------------------------------------------------------------------

insert into public.metodos_pago (usuario_id, nombre)
select p.id, 'Efectivo'
from public.profiles p
where not exists (
  select 1 from public.metodos_pago mp where mp.usuario_id = p.id
)
on conflict (usuario_id, nombre) do nothing;

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

  insert into public.metodos_pago (usuario_id, nombre)
  values (new.id, 'Efectivo')
  on conflict (usuario_id, nombre) do nothing;

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

-- ----------------------------------------------------------------------------
-- 7. Corrige un bug preexistente de las políticas "..._update": el WITH CHECK
--    revalidaba pagado_por/comprado_por en CUALQUIER edición (no solo cuando
--    esa columna cambia), así que un miembro del hogar no podía corregir nada
--    de un gasto/ítem/servicio que YA estaba pagado por otro integrante —
--    contradice que "todo el grupo puede editar" los registros del hogar.
--    La protección real (que nadie falsifique pagado_por/comprado_por a la
--    fuerza) se mueve al trigger BEFORE, que sí puede comparar contra el
--    valor anterior (RLS con check solo ve la fila nueva, no la vieja).
-- ----------------------------------------------------------------------------

create or replace function public.handle_gasto_estado()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.pagado_por is distinct from old.pagado_por
     and new.pagado_por is not null and new.pagado_por <> auth.uid() then
    raise exception 'pagado_por solo puede quedar en null o en el usuario actual';
  end if;

  if new.estado = 'pagado' and (tg_op = 'INSERT' or old.estado is distinct from 'pagado') then
    if new.fecha_pago is null then
      if tg_op = 'INSERT' then
        new.fecha_pago := coalesce(new.fecha, current_date);
      else
        new.fecha_pago := current_date;
      end if;
    end if;
    if new.pagado_por is null then
      new.pagado_por := auth.uid();
    end if;
  elsif new.estado = 'pendiente' and (tg_op = 'INSERT' or old.estado is distinct from 'pendiente') then
    new.fecha_pago := null;
    new.pagado_por := null;
  end if;
  return new;
end;
$$;

drop policy if exists "gastos_update" on public.gastos;
create policy "gastos_update" on public.gastos
  for update using (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and registrado_por = auth.uid())
  )
  with check (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and registrado_por = auth.uid())
  );

create or replace function public.handle_mercado_item_estado()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.comprado_por is distinct from old.comprado_por
     and new.comprado_por is not null and new.comprado_por <> auth.uid() then
    raise exception 'comprado_por solo puede quedar en null o en el usuario actual';
  end if;

  if new.estado = 'comprado' and (tg_op = 'INSERT' or old.estado is distinct from 'comprado') then
    if new.comprado_en is null then
      new.comprado_en := now();
    end if;
    if new.comprado_por is null then
      new.comprado_por := auth.uid();
    end if;
  elsif new.estado = 'pendiente' and (tg_op = 'INSERT' or old.estado is distinct from 'pendiente') then
    new.comprado_en := null;
    new.comprado_por := null;
  end if;
  return new;
end;
$$;

drop policy if exists "mercado_items_update" on public.mercado_items;
create policy "mercado_items_update" on public.mercado_items
  for update using (public.is_hogar_member(hogar_id))
  with check (public.is_hogar_member(hogar_id));

create or replace function public.handle_servicio_pago_estado()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and new.pagado_por is distinct from old.pagado_por
     and new.pagado_por is not null and new.pagado_por <> auth.uid() then
    raise exception 'pagado_por solo puede quedar en null o en el usuario actual';
  end if;

  if new.estado = 'pagado' and (tg_op = 'INSERT' or old.estado is distinct from 'pagado') then
    if new.fecha_pago is null then
      new.fecha_pago := current_date;
    end if;
    if new.pagado_por is null then
      new.pagado_por := auth.uid();
    end if;
  elsif new.estado = 'pendiente' and (tg_op = 'INSERT' or old.estado is distinct from 'pendiente') then
    new.fecha_pago := null;
    new.pagado_por := null;
  end if;
  return new;
end;
$$;

drop policy if exists "servicios_pagos_update" on public.servicios_pagos;
create policy "servicios_pagos_update" on public.servicios_pagos
  for update using (public.is_hogar_member(hogar_id))
  with check (public.is_hogar_member(hogar_id));

-- ============================================================================
-- Fin de la migración 012.
-- ============================================================================
