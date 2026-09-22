-- ============================================================================
-- DOMUS — Migración 003: Gastos y presupuesto mensual
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql (usa is_hogar_member()).
-- Es seguro volver a ejecutar (usa IF NOT EXISTS / DROP ... IF EXISTS).
--
-- El presupuesto mensual en sí ya existe (hogares.presupuesto_mensual, de
-- 001_init.sql); este script solo agrega el registro de gastos. Las alertas
-- de "cerca del límite" se calculan en el frontend comparando
-- SUM(gastos.monto) del mes contra ese presupuesto — no hace falta guardar
-- el porcentaje en la base de datos.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TABLA
-- ----------------------------------------------------------------------------

create table if not exists public.gastos (
  id              uuid primary key default gen_random_uuid(),
  hogar_id        uuid not null references public.hogares(id) on delete cascade,
  descripcion     text not null check (length(trim(descripcion)) > 0),
  categoria       text not null default 'otros' check (categoria in (
                    'mercado', 'servicios', 'transporte', 'salud', 'educacion',
                    'entretenimiento', 'hogar', 'mascotas', 'otros'
                  )),
  monto           numeric(12,2) not null check (monto > 0),
  metodo_pago     text not null default 'efectivo' check (metodo_pago in (
                    'efectivo', 'tarjeta_debito', 'tarjeta_credito', 'transferencia', 'otro'
                  )),
  -- Fecha en que ocurrió el gasto (puede registrarse días después); separada
  -- de created_at para que el resumen mensual refleje cuándo se gastó, no
  -- cuándo se digitó en la app.
  fecha           date not null default current_date,
  registrado_por  uuid not null references public.profiles(id),
  observaciones   text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists idx_gastos_hogar on public.gastos (hogar_id);
create index if not exists idx_gastos_hogar_fecha on public.gastos (hogar_id, fecha);

-- ----------------------------------------------------------------------------
-- 2. TRIGGERS
-- ----------------------------------------------------------------------------

drop trigger if exists trg_gastos_updated_at on public.gastos;
create trigger trg_gastos_updated_at
  before update on public.gastos
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY
-- ----------------------------------------------------------------------------

alter table public.gastos enable row level security;

-- Igual que en mercado_items: el registro de gastos es compartido por todo el
-- hogar (cualquier miembro puede ver, agregar, corregir o borrar un gasto),
-- el único límite real es pertenecer al hogar.
drop policy if exists "gastos_select" on public.gastos;
create policy "gastos_select" on public.gastos
  for select using (public.is_hogar_member(hogar_id));

drop policy if exists "gastos_insert" on public.gastos;
create policy "gastos_insert" on public.gastos
  for insert with check (
    public.is_hogar_member(hogar_id) and registrado_por = auth.uid()
  );

drop policy if exists "gastos_update" on public.gastos;
create policy "gastos_update" on public.gastos
  for update using (public.is_hogar_member(hogar_id))
  with check (public.is_hogar_member(hogar_id));

drop policy if exists "gastos_delete" on public.gastos;
create policy "gastos_delete" on public.gastos
  for delete using (public.is_hogar_member(hogar_id));

-- ============================================================================
-- Fin de la migración 003.
-- ============================================================================
