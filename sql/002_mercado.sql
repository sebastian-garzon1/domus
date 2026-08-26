-- ============================================================================
-- DOMUS — Migración 002: Mercado y lista de compras compartida
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql (usa is_hogar_member()).
-- Es seguro volver a ejecutar (usa IF NOT EXISTS / DROP ... IF EXISTS).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TABLA
-- ----------------------------------------------------------------------------

create table if not exists public.mercado_items (
  id               uuid primary key default gen_random_uuid(),
  hogar_id         uuid not null references public.hogares(id) on delete cascade,
  nombre           text not null check (length(trim(nombre)) > 0),
  categoria        text not null default 'otros' check (categoria in (
                     'despensa', 'lacteos_huevos', 'carnes_pescado', 'frutas_verduras',
                     'panaderia', 'bebidas', 'aseo_hogar', 'cuidado_personal',
                     'mascotas', 'otros'
                   )),
  cantidad         numeric(10,2) not null default 1 check (cantidad > 0),
  unidad           text not null default 'unidad' check (unidad in (
                     'unidad', 'kg', 'g', 'l', 'ml', 'paquete', 'docena', 'caja'
                   )),
  prioridad        text not null default 'media' check (prioridad in ('alta', 'media', 'baja')),
  precio_estimado  numeric(12,2) check (precio_estimado is null or precio_estimado >= 0),
  precio_final     numeric(12,2) check (precio_final is null or precio_final >= 0),
  agregado_por     uuid not null references public.profiles(id),
  comprado_por     uuid references public.profiles(id),
  estado           text not null default 'pendiente' check (estado in ('pendiente', 'comprado')),
  observaciones    text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  comprado_en      timestamptz,
  -- Un ítem "comprado" siempre debe tener fecha de compra, y viceversa: evita
  -- estados inconsistentes si alguien actualiza la fila a mano (ej. SQL Editor).
  constraint mercado_items_comprado_en_coherente check (
    (estado = 'comprado' and comprado_en is not null)
    or (estado = 'pendiente' and comprado_en is null)
  )
);

create index if not exists idx_mercado_items_hogar on public.mercado_items (hogar_id);
create index if not exists idx_mercado_items_hogar_estado on public.mercado_items (hogar_id, estado);

-- ----------------------------------------------------------------------------
-- 2. TRIGGERS
-- ----------------------------------------------------------------------------

drop trigger if exists trg_mercado_items_updated_at on public.mercado_items;
create trigger trg_mercado_items_updated_at
  before update on public.mercado_items
  for each row execute function public.set_updated_at();

-- Al marcar un ítem como "comprado" completa automáticamente comprado_en (si no
-- vino en el UPDATE) y comprado_por (si no vino, usa el usuario autenticado).
-- Al volver un ítem a "pendiente" (se reabre) limpia esos dos campos para no
-- dejar rastros de una compra que ya no aplica; precio_final se conserva como
-- referencia porque puede servir de estimado para la próxima vez.
create or replace function public.handle_mercado_item_estado()
returns trigger
language plpgsql
as $$
begin
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

drop trigger if exists trg_mercado_items_estado on public.mercado_items;
create trigger trg_mercado_items_estado
  before insert or update on public.mercado_items
  for each row execute function public.handle_mercado_item_estado();

-- ----------------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY
-- ----------------------------------------------------------------------------

alter table public.mercado_items enable row level security;

-- La lista de mercado es de todo el hogar: cualquier miembro puede ver, agregar,
-- editar (marcar comprado, ajustar precio, etc.) y borrar ítems — no solo quien
-- los creó ni solo el administrador. El único límite es pertenecer al hogar.
drop policy if exists "mercado_items_select" on public.mercado_items;
create policy "mercado_items_select" on public.mercado_items
  for select using (public.is_hogar_member(hogar_id));

drop policy if exists "mercado_items_insert" on public.mercado_items;
create policy "mercado_items_insert" on public.mercado_items
  for insert with check (
    public.is_hogar_member(hogar_id) and agregado_por = auth.uid()
  );

-- with check evita que alguien se adjudique una compra ajena al marcar el
-- ítem como comprado (comprado_por solo puede ser null o el propio usuario;
-- el trigger de arriba ya lo llena automáticamente con auth.uid()).
drop policy if exists "mercado_items_update" on public.mercado_items;
create policy "mercado_items_update" on public.mercado_items
  for update using (public.is_hogar_member(hogar_id))
  with check (
    public.is_hogar_member(hogar_id)
    and (comprado_por is null or comprado_por = auth.uid())
  );

drop policy if exists "mercado_items_delete" on public.mercado_items;
create policy "mercado_items_delete" on public.mercado_items
  for delete using (public.is_hogar_member(hogar_id));

-- ============================================================================
-- Fin de la migración 002.
-- ============================================================================
