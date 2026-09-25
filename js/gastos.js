// ============================================================================
// DOMUS — Gastos (del momento y recurrentes, personales y del hogar)
// ============================================================================
import { supabase } from './supabaseClient.js';

// Mismo bucket privado que usa servicios.js — sus políticas de Storage solo
// exigen que la ruta empiece por "{hogar_id}/..." (gastos del hogar) o por
// "personal/{usuario_id}/..." (gastos personales), sin importar qué tabla
// referencia el archivo.
const BUCKET = 'comprobantes';

/** Catálogo de categorías (debe coincidir con los CHECK de sql/003 y sql/008). */
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

// registrado_por y pagado_por son dos FK distintas hacia profiles: hay que
// nombrar la relación explícitamente (igual que en servicios_pagos), si no
// PostgREST no sabe cuál de las dos usar.
const SELECT_GASTO = `
  *,
  registrado_por_perfil:profiles!gastos_registrado_por_fkey (id, nombre_completo, email),
  pagado_por_perfil:profiles!gastos_pagado_por_fkey (id, nombre_completo, email)
`;

/**
 * Fecha de HOY en la zona horaria del dispositivo, como "YYYY-MM-DD".
 * new Date().toISOString() usa UTC: en Colombia (UTC-5) eso adelanta el día
 * durante la noche (ej. 11pm del 22 ya calcula 23 en UTC). Ver también
 * fechaLocalHoy() en js/ui.js (misma lógica, duplicada a propósito para no
 * acoplar este módulo de datos a uno de interfaz).
 */
function hoyLocal() {
  const hoy = new Date();
  const mes = String(hoy.getMonth() + 1).padStart(2, '0');
  const dia = String(hoy.getDate()).padStart(2, '0');
  return `${hoy.getFullYear()}-${mes}-${dia}`;
}

async function usuarioActualId() {
  const { data: usuario } = await supabase.auth.getUser();
  if (!usuario?.user) throw new Error('No hay sesión activa');
  return usuario.user.id;
}

/**
 * Lista los gastos visibles para el usuario actual en este hogar: los del
 * hogar (de cualquier miembro) más los personales propios — RLS ya filtra
 * los personales de otras personas, no hace falta excluirlos aquí.
 */
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

/** Gasto "del momento": ya pagado desde el instante en que se registra. */
export async function agregarGasto(hogarId, campos) {
  const usuarioId = await usuarioActualId();

  const { data, error } = await supabase
    .from('gastos')
    .insert({
      hogar_id: hogarId,
      descripcion: campos.descripcion,
      categoria: campos.categoria || 'otros',
      monto: campos.monto,
      metodo_pago: campos.metodoPago || 'efectivo',
      fecha: campos.fecha || hoyLocal(),
      observaciones: campos.observaciones || null,
      es_personal: !!campos.esPersonal,
      registrado_por: usuarioId,
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

export async function marcarGastoPagado(gastoId) {
  await actualizarGasto(gastoId, { estado: 'pagado' });
}

/** Reabre un gasto pendiente que se había marcado pagado por error. */
export async function reabrirGasto(gastoId) {
  await actualizarGasto(gastoId, { estado: 'pendiente' });
}

export async function eliminarGasto(gastoId) {
  const { error } = await supabase.from('gastos').delete().eq('id', gastoId);
  if (error) throw error;
}

/**
 * Sube el comprobante de un gasto al bucket privado "comprobantes". Los
 * gastos del hogar van bajo "{hogarId}/..." (visible a todo el hogar); los
 * personales van bajo "personal/{usuarioId}/..." (solo el dueño puede verlo,
 * ver políticas de Storage en sql/008_gastos_recurrentes_personales.sql).
 */
export async function subirComprobanteGasto(hogarId, gastoId, archivo, esPersonal = false) {
  const nombreSeguro = archivo.name.replace(/[^a-zA-Z0-9._-]/g, '_');
  const prefijo = esPersonal ? `personal/${await usuarioActualId()}` : hogarId;
  const path = `${prefijo}/gasto-${gastoId}-${Date.now()}-${nombreSeguro}`;

  const { error: errorSubida } = await supabase.storage.from(BUCKET).upload(path, archivo, {
    upsert: false,
  });
  if (errorSubida) throw errorSubida;

  await actualizarGasto(gastoId, { comprobante_path: path });
  return path;
}

/** Bucket privado: no hay URL pública, se pide una firmada de corta duración. */
export async function obtenerUrlComprobanteGasto(path) {
  const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(path, 60);
  if (error) throw error;
  return data.signedUrl;
}

// --- Gastos recurrentes (plantillas) ----------------------------------------

export async function listarRecurrentes(hogarId) {
  const { data, error } = await supabase
    .from('gastos_recurrentes')
    .select('*')
    .eq('hogar_id', hogarId)
    .order('dia_mes', { ascending: true });
  if (error) throw error;
  return data;
}

export async function agregarRecurrente(hogarId, campos) {
  const usuarioId = await usuarioActualId();

  const { data, error } = await supabase
    .from('gastos_recurrentes')
    .insert({
      hogar_id: hogarId,
      descripcion: campos.descripcion,
      categoria: campos.categoria || 'otros',
      monto: campos.monto,
      metodo_pago: campos.metodoPago || 'efectivo',
      dia_mes: campos.diaMes,
      es_personal: !!campos.esPersonal,
      numero_referencia: campos.numeroReferencia || null,
      enlace_pago: campos.enlacePago || null,
      creado_por: usuarioId,
    })
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function actualizarRecurrente(recurrenteId, cambios) {
  const { error } = await supabase.from('gastos_recurrentes').update(cambios).eq('id', recurrenteId);
  if (error) throw error;
}

export async function alternarActivoRecurrente(recurrenteId, activo) {
  await actualizarRecurrente(recurrenteId, { activo });
}

export async function eliminarRecurrente(recurrenteId) {
  const { error } = await supabase.from('gastos_recurrentes').delete().eq('id', recurrenteId);
  if (error) throw error;
}

/** Día de vencimiento de este mes, topando al último día real del mes. */
function fechaDelMes(diaMes, referencia = new Date()) {
  const anio = referencia.getFullYear();
  const mes = referencia.getMonth();
  const ultimoDiaMes = new Date(anio, mes + 1, 0).getDate();
  const dia = Math.min(diaMes, ultimoDiaMes);
  return `${anio}-${String(mes + 1).padStart(2, '0')}-${String(dia).padStart(2, '0')}`;
}

/**
 * Genera el gasto pendiente del mes actual para cada plantilla activa que
 * todavía no lo tenga (botón "Generar pendientes del mes"). Devuelve cuántos
 * se crearon.
 */
export async function generarPendientesDelMes(hogarId) {
  const usuarioId = await usuarioActualId();
  const [recurrentes, gastosExistentes] = await Promise.all([
    listarRecurrentes(hogarId),
    listarGastos(hogarId),
  ]);

  const activas = recurrentes.filter((r) => r.activo);
  const hoy = new Date();
  const mesActual = hoy.getMonth();
  const anioActual = hoy.getFullYear();

  const yaGenerados = new Set(
    gastosExistentes
      .filter((g) => g.recurrente_id)
      .filter((g) => {
        const f = new Date(g.fecha + 'T00:00:00');
        return f.getMonth() === mesActual && f.getFullYear() === anioActual;
      })
      .map((g) => g.recurrente_id)
  );

  const pendientesPorCrear = activas.filter((r) => !yaGenerados.has(r.id));
  if (pendientesPorCrear.length === 0) return 0;

  const filas = pendientesPorCrear.map((r) => ({
    hogar_id: hogarId,
    descripcion: r.descripcion,
    categoria: r.categoria,
    monto: r.monto,
    metodo_pago: r.metodo_pago,
    fecha: fechaDelMes(r.dia_mes, hoy),
    estado: 'pendiente',
    es_personal: r.es_personal,
    numero_referencia: r.numero_referencia,
    enlace_pago: r.enlace_pago,
    recurrente_id: r.id,
    registrado_por: usuarioId,
  }));

  const { error } = await supabase.from('gastos').insert(filas);
  if (error) throw error;
  return filas.length;
}

/**
 * Calcula el resumen del mes actual contra el presupuesto del hogar: total
 * gastado (ya pagado), porcentaje usado, y un nivel de alerta para colorear
 * la UI. presupuestoMensual llega de hogares.presupuesto_mensual.
 */
export function calcularResumenMes(gastos, presupuestoMensual) {
  const ahora = new Date();
  // El presupuesto es del HOGAR: los gastos personales no cuentan aquí (son
  // de quien los hizo, no salen de la plata compartida). Sí siguen viéndose
  // en la lista normal de Gastos, solo no entran en este resumen.
  const delMes = gastos.filter((g) => {
    if (g.estado !== 'pagado' || !g.fecha_pago || g.es_personal) return false;
    const fecha = new Date(g.fecha_pago + 'T00:00:00');
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

  const pendientes = gastos.filter((g) => g.estado === 'pendiente' && !g.es_personal);

  return {
    totalGastado,
    presupuesto,
    porcentaje: Math.min(porcentaje, 999),
    nivelAlerta,
    countGastosMes: delMes.length,
    porCategoria,
    countPendientes: pendientes.length,
    totalPendiente: pendientes.reduce((suma, g) => suma + Number(g.monto), 0),
  };
}

/** Agrupa los gastos pendientes por fecha ("YYYY-MM-DD" -> lista), para el calendario. */
export function agruparGastosPorFecha(gastos) {
  const porFecha = new Map();
  for (const g of gastos) {
    if (g.estado !== 'pendiente' || !g.fecha) continue;
    if (!porFecha.has(g.fecha)) porFecha.set(g.fecha, []);
    porFecha.get(g.fecha).push(g);
  }
  return porFecha;
}
