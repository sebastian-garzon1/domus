-- ============================================================================
-- DOMUS — Migración 014b: el trigger de saldo ignora montos nulos
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- (en una pestaña NUEVA, no reuses la de sql/014a)
-- Requiere haber corrido antes sql/014a.
-- Es seguro volver a ejecutar (create or replace).
-- Parte 2 de 3 — después sigue sql/014c.
--
-- Por qué separado: esta es la única parte de la migración 014 que define
-- una función con cuerpo $func$...$func$; si tu editor llegó a cortar un
-- pegado largo a la mitad, aislar esto en su propia pestaña, corta y sola,
-- hace más fácil confirmar que se pegó completo.
-- ============================================================================

create or replace function public.sync_metodo_pago_gastos()
returns trigger
language plpgsql
security definer
set search_path = public
as $func$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if old.estado = 'pagado' and old.metodo_pago_id is not null and old.monto is not null then
      update public.metodos_pago set saldo = saldo + old.monto where id = old.metodo_pago_id;
      delete from public.metodo_pago_movimientos where gasto_id = old.id;
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    if new.estado = 'pagado' and new.metodo_pago_id is not null and new.monto is not null then
      update public.metodos_pago set saldo = saldo - new.monto where id = new.metodo_pago_id;
      insert into public.metodo_pago_movimientos (metodo_pago_id, usuario_id, tipo, monto, descripcion, gasto_id)
      values (new.metodo_pago_id, new.registrado_por, 'gasto', new.monto, new.descripcion, new.id);
    end if;
  end if;

  return coalesce(new, old);
end;
$func$;

-- ============================================================================
-- Fin de la migración 014b. Sigue con sql/014c en una pestaña nueva.
-- ============================================================================
