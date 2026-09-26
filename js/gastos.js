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

export function etiquetaCategoria(valor) {
  return CATEGORIAS.find((c) => c.valor === valor)?.etiqueta ?? valor;
}

// registrado_por y pagado_por son dos FK distintas hacia profiles: hay que
// nombrar la relación explícitamente (igual que en servicios_pagos), si no
// PostgREST no sabe cuál de las dos usar. metodo_pago trae solo el nombre del
// método de pago personal elegido (ver js/metodosPago.js) — puede ser null.
const SELECT_GASTO = `
  *,
  registrado_por_perfil:profiles!gastos_registrado_por_fkey (id, nombre_completo, email),
  pagado_por_perfil:profiles!gastos_pagado_por_fkey (id, nombre_completo, email),
  metodo_pago:metodos_pago (id, nombre)
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
 * Lista los gastos visibles para el usuario actual: los del hogar indicado
 * (de cualquier miembro) más TODOS sus gastos personales propios, sin
 * importar en qué hogar los haya registrado — un gasto personal es del
 * usuario, no del hogar, así que no debe desaparecer al cambiar de hogar
 * activo. hogar_id en un gasto personal solo queda como dato de dónde se
 * creó, nunca se usa para filtrar su visibilidad.
 */
export async function listarGastos(hogarId) {
  const usuarioId = await usuarioActualId();
  const consultas = [supabase.from('gastos').select(SELECT_GASTO).eq('es_personal', true).eq('registrado_por', usuarioId)];
  // Sin hogar activo (ej. usuario que todavía no crea/entra a ningún hogar)
  // simplemente no hay gastos del hogar que traer — los personales igual se ven.
  if (hogarId) {
    consultas.push(supabase.from('gastos').select(SELECT_GASTO).eq('hogar_id', hogarId).eq('es_personal', false));
  }
  const resultados = await Promise.all(consultas);
  for (const r of resultados) if (r.error) throw r.error;

  return resultados
    .flatMap((r) => r.data)
    .sort((a, b) => {
      if (a.fecha !== b.fecha) return a.fecha < b.fecha ? 1 : -1;
      return new Date(b.created_at) - new Date(a.created_at);
    });
}

/**
 * Gasto "del momento": ya pagado desde el instante en que se registra.
 * hogarId puede ser null solo si campos.esPersonal es true (un gasto del
 * hogar siempre necesita un hogar_id, lo exige la base de datos).
 */
export async function agregarGasto(hogarId, campos) {
  const usuarioId = await usuarioActualId();
  if (!campos.esPersonal && !hogarId) {
    throw new Error('Selecciona un hogar para registrar un gasto compartido');
  }

  const { data, error } = await supabase
    .from('gastos')
    .insert({
      hogar_id: hogarId || null,
      descripcion: campos.descripcion,
      categoria: campos.categoria || 'otros',
      monto: campos.monto,
      metodo_pago_id: campos.metodoPagoId || null,
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

/** metodoPagoId es opcional: con qué método se pagó (descuenta su saldo, ver sql/012). */
export async function marcarGastoPagado(gastoId, metodoPagoId) {
  const cambios = { estado: 'pagado' };
  if (metodoPagoId) cambios.metodo_pago_id = metodoPagoId;
  await actualizarGasto(gastoId, cambios);
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

const SELECT_RECURRENTE = '*, metodo_pago:metodos_pago (id, nombre)';

/** Mismo criterio que listarGastos: las plantillas personales no dependen del hogar activo. */
export async function listarRecurrentes(hogarId) {
  const usuarioId = await usuarioActualId();
  const consultas = [
    supabase.from('gastos_recurrentes').select(SELECT_RECURRENTE).eq('es_personal', true).eq('creado_por', usuarioId),
  ];
  if (hogarId) {
    consultas.push(
      supabase.from('gastos_recurrentes').select(SELECT_RECURRENTE).eq('hogar_id', hogarId).eq('es_personal', false)
    );
  }
  const resultados = await Promise.all(consultas);
  for (const r of resultados) if (r.error) throw r.error;

  return resultados.flatMap((r) => r.data).sort((a, b) => a.dia_mes - b.dia_mes);
}

/** hogarId puede ser null solo si campos.esPersonal es true (ver agregarGasto). */
export async function agregarRecurrente(hogarId, campos) {
  const usuarioId = await usuarioActualId();
  if (!campos.esPersonal && !hogarId) {
    throw new Error('Selecciona un hogar para registrar un recurrente compartido');
  }

  const { data, error } = await supabase
    .from('gastos_recurrentes')
    .insert({
      hogar_id: hogarId || null,
      descripcion: campos.descripcion,
      categoria: campos.categoria || 'otros',
      monto: campos.monto,
      metodo_pago_id: campos.metodoPagoId || null,
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

async function actualizarRecurrente(recurrenteId, cambios) {
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
    hogar_id: r.hogar_id,
    descripcion: r.descripcion,
    categoria: r.categoria,
    monto: r.monto,
    metodo_pago_id: r.metodo_pago_id,
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
 * Resumen del mes actual para una lista de gastos ya filtrada (el llamador
 * decide el alcance: del hogar, personales, o ambos — esta función no sabe
 * nada de hogares ni de presupuestos, solo suma lo que le pasan).
 */
export function calcularResumenMes(gastos) {
  const ahora = new Date();
  const delMes = gastos.filter((g) => {
    if (g.estado !== 'pagado' || !g.fecha_pago) return false;
    const fecha = new Date(g.fecha_pago + 'T00:00:00');
    return fecha.getFullYear() === ahora.getFullYear() && fecha.getMonth() === ahora.getMonth();
  });

  const totalGastado = delMes.reduce((suma, g) => suma + Number(g.monto), 0);

  const porCategoria = {};
  for (const g of delMes) {
    porCategoria[g.categoria] = (porCategoria[g.categoria] || 0) + Number(g.monto);
  }

  const pendientes = gastos.filter((g) => g.estado === 'pendiente');

  return {
    totalGastado,
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
