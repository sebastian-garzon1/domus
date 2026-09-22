// ============================================================================
// DOMUS — Gastos generales y presupuesto mensual
// ============================================================================
import { supabase } from './supabaseClient.js';

/** Catálogo de categorías (debe coincidir con el CHECK de sql/003_gastos.sql). */
export const CATEGORIAS = [
  { valor: 'mercado', etiqueta: 'Mercado' },
  { valor: 'servicios', etiqueta: 'Servicios' },
  { valor: 'transporte', etiqueta: 'Transporte' },
  { valor: 'salud', etiqueta: 'Salud' },
  { valor: 'educacion', etiqueta: 'Educación' },
  { valor: 'entretenimiento', etiqueta: 'Entretenimiento' },
  { valor: 'hogar', etiqueta: 'Hogar' },
  { valor: 'mascotas', etiqueta: 'Mascotas' },
  { valor: 'otros', etiqueta: 'Otros' },
];

/** Catálogo de métodos de pago (debe coincidir con el CHECK de sql/003_gastos.sql). */
export const METODOS_PAGO = [
  { valor: 'efectivo', etiqueta: 'Efectivo' },
  { valor: 'tarjeta_debito', etiqueta: 'Tarjeta débito' },
  { valor: 'tarjeta_credito', etiqueta: 'Tarjeta crédito' },
  { valor: 'transferencia', etiqueta: 'Transferencia' },
  { valor: 'otro', etiqueta: 'Otro' },
];

export function etiquetaCategoria(valor) {
  return CATEGORIAS.find((c) => c.valor === valor)?.etiqueta ?? valor;
}

export function etiquetaMetodoPago(valor) {
  return METODOS_PAGO.find((m) => m.valor === valor)?.etiqueta ?? valor;
}

// registrado_por es la única FK de gastos hacia profiles, así que a diferencia
// de mercado_items no hace falta nombrar la relación explícitamente.
const SELECT_GASTO = `
  *,
  registrado_por_perfil:profiles (id, nombre_completo, email)
`;

/** Lista los gastos de un hogar, más recientes primero. */
export async function listarGastos(hogarId) {
  const { data, error } = await supabase
    .from('gastos')
    .select(SELECT_GASTO)
    .eq('hogar_id', hogarId)
    .order('fecha', { ascending: false })
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

export async function agregarGasto(hogarId, campos) {
  const { data: usuario } = await supabase.auth.getUser();
  if (!usuario?.user) throw new Error('No hay sesión activa');

  const { data, error } = await supabase
    .from('gastos')
    .insert({
      hogar_id: hogarId,
      descripcion: campos.descripcion,
      categoria: campos.categoria || 'otros',
      monto: campos.monto,
      metodo_pago: campos.metodoPago || 'efectivo',
      fecha: campos.fecha || new Date().toISOString().slice(0, 10),
      observaciones: campos.observaciones || null,
      registrado_por: usuario.user.id,
    })
    .select(SELECT_GASTO)
    .single();
  if (error) throw error;
  return data;
}

export async function actualizarGasto(gastoId, cambios) {
  const { error } = await supabase.from('gastos').update(cambios).eq('id', gastoId);
  if (error) throw error;
}

export async function eliminarGasto(gastoId) {
  const { error } = await supabase.from('gastos').delete().eq('id', gastoId);
  if (error) throw error;
}

/**
 * Calcula el resumen del mes actual contra el presupuesto del hogar: total
 * gastado, porcentaje usado, y un nivel de alerta para colorear la UI.
 * presupuestoMensual llega de hogares.presupuesto_mensual (ya existente).
 */
export function calcularResumenMes(gastos, presupuestoMensual) {
  const ahora = new Date();
  const delMes = gastos.filter((g) => {
    const fecha = new Date(g.fecha + 'T00:00:00');
    return fecha.getFullYear() === ahora.getFullYear() && fecha.getMonth() === ahora.getMonth();
  });

  const totalGastado = delMes.reduce((suma, g) => suma + Number(g.monto), 0);
  const presupuesto = Number(presupuestoMensual) || 0;
  const porcentaje = presupuesto > 0 ? (totalGastado / presupuesto) * 100 : 0;

  let nivelAlerta = 'ok'; // ok | cerca | excedido
  if (presupuesto > 0) {
    if (porcentaje >= 100) nivelAlerta = 'excedido';
    else if (porcentaje >= 80) nivelAlerta = 'cerca';
  }

  const porCategoria = {};
  for (const g of delMes) {
    porCategoria[g.categoria] = (porCategoria[g.categoria] || 0) + Number(g.monto);
  }

  return {
    totalGastado,
    presupuesto,
    porcentaje: Math.min(porcentaje, 999),
    nivelAlerta,
    countGastosMes: delMes.length,
    porCategoria,
  };
}
