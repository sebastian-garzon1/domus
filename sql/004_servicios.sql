-- ============================================================================
-- DOMUS — Migración 004: Servicios y pagos recurrentes (+ comprobantes)
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql (usa is_hogar_member()).
-- Es seguro volver a ejecutar (usa IF NOT EXISTS / DROP ... IF EXISTS).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TABLA
-- ----------------------------------------------------------------------------

create table if not exists public.servicios_pagos (
  id                uuid primary key default gen_random_uuid(),
  hogar_id          uuid not null references public.hogares(id) on delete cascade,
  nombre            text not null check (length(trim(nombre)) > 0),
  categoria         text not null default 'otros' check (categoria in (
                      'energia', 'agua', 'gas', 'internet', 'telefono',
                      'arriendo', 'streaming', 'seguro', 'otros'
                    )),
  monto             numeric(12,2) not null check (monto > 0),
  fecha_vencimiento date not null,
  estado            text not null default 'pendiente' check (estado in ('pendiente', 'pagado')),
  fecha_pago        date,
  pagado_por        uuid references public.profiles(id),
  -- Ruta del comprobante en el bucket de Storage "comprobantes", con el
  -- formato {hogar_id}/{archivo} (ver política de Storage más abajo, que se
  -- basa en ese primer segmento de la ruta para aislar por hogar). Null
  -- mientras no se haya subido ningún comprobante para este pago.
  comprobante_path  text,
  registrado_por    uuid not null references public.profiles(id),
  observaciones     text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  -- Igual que en mercado_items: un pago "pagado" siempre debe tener fecha de
  -- pago, y viceversa, para que no queden estados inconsistentes.
  constraint servicios_pagos_pago_coherente check (
    (estado = 'pagado' and fecha_pago is not null)
    or (estado = 'pendiente' and fecha_pago is null)
  )
);

create index if not exists idx_servicios_pagos_hogar on public.servicios_pagos (hogar_id);
create index if not exists idx_servicios_pagos_hogar_estado on public.servicios_pagos (hogar_id, estado);
create index if not exists idx_servicios_pagos_vencimiento on public.servicios_pagos (hogar_id, fecha_vencimiento);

-- ----------------------------------------------------------------------------
-- 2. TRIGGERS
-- ----------------------------------------------------------------------------

drop trigger if exists trg_servicios_pagos_updated_at on public.servicios_pagos;
create trigger trg_servicios_pagos_updated_at
  before update on public.servicios_pagos
  for each row execute function public.set_updated_at();

-- Mismo patrón que mercado_items: al marcar "pagado" completa fecha_pago y
-- pagado_por automáticamente si no vinieron en el UPDATE; al reabrir
-- ("pendiente") los limpia. comprobante_path se conserva al reabrir, porque
-- el comprobante ya subido sigue siendo válido como referencia.
create or replace function public.handle_servicio_pago_estado()
returns trigger
language plpgsql
as $$
begin
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

drop trigger if exists trg_servicios_pagos_estado on public.servicios_pagos;
create trigger trg_servicios_pagos_estado
  before insert or update on public.servicios_pagos
  for each row execute function public.handle_servicio_pago_estado();

-- ----------------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY (tabla)
-- ----------------------------------------------------------------------------

alter table public.servicios_pagos enable row level security;

drop policy if exists "servicios_pagos_select" on public.servicios_pagos;
create policy "servicios_pagos_select" on public.servicios_pagos
  for select using (public.is_hogar_member(hogar_id));

drop policy if exists "servicios_pagos_insert" on public.servicios_pagos;
create policy "servicios_pagos_insert" on public.servicios_pagos
  for insert with check (
    public.is_hogar_member(hogar_id) and registrado_por = auth.uid()
  );

-- with check evita que alguien se adjudique un pago ajeno (pagado_por solo
-- puede ser null o el propio usuario; el trigger de arriba ya lo completa).
drop policy if exists "servicios_pagos_update" on public.servicios_pagos;
create policy "servicios_pagos_update" on public.servicios_pagos
  for update using (public.is_hogar_member(hogar_id))
  with check (
    public.is_hogar_member(hogar_id)
    and (pagado_por is null or pagado_por = auth.uid())
  );

drop policy if exists "servicios_pagos_delete" on public.servicios_pagos;
create policy "servicios_pagos_delete" on public.servicios_pagos
  for delete using (public.is_hogar_member(hogar_id));

-- ----------------------------------------------------------------------------
-- 4. STORAGE: bucket "comprobantes" + RLS de storage.objects
-- ----------------------------------------------------------------------------
-- Bucket privado (public = false): nadie puede leer un comprobante solo por
-- adivinar/tener la URL, todo pasa por estas políticas de RLS igual que las
-- tablas. El frontend sube a la ruta "{hogar_id}/{archivo}" y pide URLs
-- firmadas de corta duración para mostrarlas, nunca URLs públicas.

insert into storage.buckets (id, name, public)
values ('comprobantes', 'comprobantes', false)
on conflict (id) do nothing;

-- storage.objects ya tiene RLS habilitado por Supabase; solo agregamos las
-- políticas. (storage.foldername(name))[1] es el primer segmento de la ruta
-- del archivo, que en nuestra convención es siempre el hogar_id.
drop policy if exists "comprobantes_select" on storage.objects;
create policy "comprobantes_select" on storage.objects
  for select using (
    bucket_id = 'comprobantes'
    and public.is_hogar_member((storage.foldername(name))[1]::uuid)
  );

drop policy if exists "comprobantes_insert" on storage.objects;
create policy "comprobantes_insert" on storage.objects
  for insert with check (
    bucket_id = 'comprobantes'
    and public.is_hogar_member((storage.foldername(name))[1]::uuid)
  );

drop policy if exists "comprobantes_update" on storage.objects;
create policy "comprobantes_update" on storage.objects
  for update using (
    bucket_id = 'comprobantes'
    and public.is_hogar_member((storage.foldername(name))[1]::uuid)
  );

drop policy if exists "comprobantes_delete" on storage.objects;
create policy "comprobantes_delete" on storage.objects
  for delete using (
    bucket_id = 'comprobantes'
    and public.is_hogar_member((storage.foldername(name))[1]::uuid)
  );

-- ============================================================================
-- Fin de la migración 004.
-- ============================================================================
