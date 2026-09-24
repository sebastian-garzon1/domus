-- ============================================================================
-- DOMUS — Migración 011: servicios recurrentes (plantillas mensuales)
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql y sql/004_servicios.sql.
-- Es seguro volver a ejecutar (usa IF NOT EXISTS / DROP ... IF EXISTS).
--
-- Mismo patrón que gastos_recurrentes (sql/008), pero sin la parte
-- "personal": los servicios siempre son del hogar completo, así que la
-- plantilla es más simple. Crea la plantilla una vez (nombre, monto, día del
-- mes) y cada mes, desde la pestaña "Recurrentes" de Servicios, se presiona
-- "Generar pendientes del mes" para crear el pago pendiente correspondiente
-- (generación manual, no automática por cron).
-- ============================================================================

create table if not exists public.servicios_recurrentes (
  id                uuid primary key default gen_random_uuid(),
  hogar_id          uuid not null references public.hogares(id) on delete cascade,
  nombre            text not null check (length(trim(nombre)) > 0),
  categoria         text not null default 'otros' check (categoria in (
                      'energia', 'agua', 'gas', 'internet', 'telefono',
                      'arriendo', 'streaming', 'seguro', 'otros'
                    )),
  monto             numeric(12,2) not null check (monto > 0),
  -- Día del mes en que vence (topado a 28 para que exista en todos los meses).
  dia_mes           int not null check (dia_mes between 1 and 28),
  numero_referencia text,
  enlace_pago       text,
  activo            boolean not null default true,
  creado_por        uuid not null references public.profiles(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint servicios_recurrentes_enlace_pago_valido check (
    enlace_pago is null or enlace_pago ~ '^https?://'
  )
);

create index if not exists idx_servicios_recurrentes_hogar on public.servicios_recurrentes (hogar_id);

drop trigger if exists trg_servicios_recurrentes_updated_at on public.servicios_recurrentes;
create trigger trg_servicios_recurrentes_updated_at
  before update on public.servicios_recurrentes
  for each row execute function public.set_updated_at();

alter table public.servicios_recurrentes enable row level security;

-- Mismo criterio que servicios_pagos: cualquier miembro del hogar puede ver,
-- crear, editar y borrar plantillas recurrentes; no hay noción de "personal".
drop policy if exists "servicios_recurrentes_select" on public.servicios_recurrentes;
create policy "servicios_recurrentes_select" on public.servicios_recurrentes
  for select using (public.is_hogar_member(hogar_id));

drop policy if exists "servicios_recurrentes_insert" on public.servicios_recurrentes;
create policy "servicios_recurrentes_insert" on public.servicios_recurrentes
  for insert with check (
    public.is_hogar_member(hogar_id) and creado_por = auth.uid()
  );

drop policy if exists "servicios_recurrentes_update" on public.servicios_recurrentes;
create policy "servicios_recurrentes_update" on public.servicios_recurrentes
  for update using (public.is_hogar_member(hogar_id))
  with check (public.is_hogar_member(hogar_id));

drop policy if exists "servicios_recurrentes_delete" on public.servicios_recurrentes;
create policy "servicios_recurrentes_delete" on public.servicios_recurrentes
  for delete using (public.is_hogar_member(hogar_id));

-- ----------------------------------------------------------------------------
-- Enlaza cada pago generado con la plantilla que lo originó (opcional: los
-- servicios registrados a mano, como hasta ahora, quedan con recurrente_id
-- en null).
-- ----------------------------------------------------------------------------

alter table public.servicios_pagos
  add column if not exists recurrente_id uuid references public.servicios_recurrentes(id) on delete set null;

-- ============================================================================
-- Fin de la migración 011.
-- ============================================================================
