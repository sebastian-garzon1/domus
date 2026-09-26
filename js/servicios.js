// ============================================================================
// DOMUS — Servicios y pagos recurrentes (+ comprobantes en Supabase Storage)
// ============================================================================
import { supabase } from './supabaseClient.js';

const BUCKET = 'comprobantes';

/** Catálogo de categorías (debe coincidir con el CHECK de sql/004_servicios.sql). */
export const CATEGORIAS = [
  { valor: 'energia', etiqueta: 'Energía' },
  { valor: 'agua', etiqueta: 'Agua' },
  { valor: 'gas', etiqueta: 'Gas' },
  { valor: 'internet', etiqueta: 'Internet' },
  { valor: 'telefono', etiqueta: 'Teléfono' },
  { valor: 'arriendo', etiqueta: 'Arriendo' },
  { valor: 'streaming', etiqueta: 'Streaming' },
  { valor: 'seguro', etiqueta: 'Seguro' },
  { valor: 'otros', etiqueta: 'Otros' },
];

export function etiquetaCategoria(valor) {
  return CATEGORIAS.find((c) => c.valor === valor)?.etiqueta ?? valor;
}

// registrado_por y pagado_por son dos FK distintas hacia profiles: hay que
// nombrar la relación explícitamente (igual que en mercado_items), si no
// PostgREST no sabe cuál de las dos usar.
const SELECT_SERVICIO = `
  *,
  registrado_por_perfil:profiles!servicios_pagos_registrado_por_fkey (id, nombre_completo, email),
  pagado_por_perfil:profiles!servicios_pagos_pagado_por_fkey (id, nombre_completo, email),
  metodo_pago:metodos_pago (id, nombre)
`;

export async function listarServicios(hogarId) {
  const { data, error } = await supabase
    .from('servicios_pagos')
    .select(SELECT_SERVICIO)
    .eq('hogar_id', hogarId)
    .order('fecha_vencimiento', { ascending: true });
  if (error) throw error;
  return data;
}

export async function agregarServicio(hogarId, campos) {
  const { data: usuario } = await supabase.auth.getUser();
  if (!usuario?.user) throw new Error('No hay sesión activa');

  const { data, error } = await supabase
    .from('servicios_pagos')
    .insert({
      hogar_id: hogarId,
      nombre: campos.nombre,
      categoria: campos.categoria || 'otros',
      monto: campos.monto,
      fecha_vencimiento: campos.fechaVencimiento,
      numero_referencia: campos.numeroReferencia || null,
      enlace_pago: campos.enlacePago || null,
      observaciones: campos.observaciones || null,
      registrado_por: usuario.user.id,
    })
    .select(SELECT_SERVICIO)
    .single();
  if (error) throw error;
  return data;
}

export async function actualizarServicio(servicioId, cambios) {
  const { error } = await supabase.from('servicios_pagos').update(cambios).eq('id', servicioId);
  if (error) throw error;
}

/** metodoPagoId es opcional: con qué método se pagó (descuenta su saldo, ver sql/012). */
export async function marcarPagado(servicioId, metodoPagoId) {
  const cambios = { estado: 'pagado' };
  if (metodoPagoId) cambios.metodo_pago_id = metodoPagoId;
  await actualizarServicio(servicioId, cambios);
}

/** Reabre un pago (vuelve a "pendiente"; el trigger limpia pagado_por/fecha_pago). */
export async function reabrirServicio(servicioId) {
  await actualizarServicio(servicioId, { estado: 'pendiente' });
}

export async function eliminarServicio(servicioId) {
  const { error } = await supabase.from('servicios_pagos').delete().eq('id', servicioId);
  if (error) throw error;
}

/**
 * Sube el comprobante de un pago al bucket privado "comprobantes", bajo
 * "{hogarId}/{servicioId}-{nombreArchivo}" (la política de Storage exige que
 * el primer segmento de la ruta sea un hogar al que el usuario pertenece), y
 * guarda esa ruta en el registro para poder pedir luego una URL firmada.
 */
export async function subirComprobante(hogarId, servicioId, archivo) {
  const rutaSegura = archivo.name.replace(/[^a-zA-Z0-9._-]/g, '_');
  const path = `${hogarId}/${servicioId}-${Date.now()}-${rutaSegura}`;

  const { error: errorSubida } = await supabase.storage.from(BUCKET).upload(path, archivo, {
    upsert: false,
  });
  if (errorSubida) throw errorSubida;

  await actualizarServicio(servicioId, { comprobante_path: path });
  return path;
}

/** Bucket privado: no hay URL pública, se pide una firmada de corta duración. */
export async function obtenerUrlComprobante(path) {
  const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(path, 60);
  if (error) throw error;
  return data.signedUrl;
}

/** Resumen para el dashboard y las tarjetas de servicios/. */
export function calcularResumenServicios(servicios) {
  const hoy = new Date();
  hoy.setHours(0, 0, 0, 0);

  const pendientes = servicios.filter((s) => s.estado === 'pendiente');
  const vencidos = pendientes.filter((s) => new Date(s.fecha_vencimiento + 'T00:00:00') < hoy);
  const proximoPago = pendientes
    .slice()
    .sort((a, b) => new Date(a.fecha_vencimiento) - new Date(b.fecha_vencimiento))[0];

  const ahora = new Date();
  const pagadosMes = servicios.filter((s) => {
    if (s.estado !== 'pagado' || !s.fecha_pago) return false;
    const fecha = new Date(s.fecha_pago + 'T00:00:00');
    return fecha.getFullYear() === ahora.getFullYear() && fecha.getMonth() === ahora.getMonth();
  });

  return {
    countPendientes: pendientes.length,
    countVencidos: vencidos.length,
    totalPendiente: pendientes.reduce((suma, s) => suma + Number(s.monto), 0),
    proximoPago: proximoPago ?? null,
    countPagadosMes: pagadosMes.length,
    totalPagadoMes: pagadosMes.reduce((suma, s) => suma + Number(s.monto), 0),
  };
}

/**
 * Agrupa los servicios por su fecha de vencimiento ("YYYY-MM-DD" -> lista),
 * para pintar el calendario mensual de servicios/.
 */
export function agruparServiciosPorFecha(servicios) {
  const porFecha = new Map();
  for (const s of servicios) {
    if (!s.fecha_vencimiento) continue;
    if (!porFecha.has(s.fecha_vencimiento)) porFecha.set(s.fecha_vencimiento, []);
    porFecha.get(s.fecha_vencimiento).push(s);
  }
  return porFecha;
}

// --- Servicios recurrentes (plantillas mensuales) ---------------------------

export async function listarRecurrentes(hogarId) {
  const { data, error } = await supabase
    .from('servicios_recurrentes')
    .select('*, metodo_pago:metodos_pago (id, nombre)')
    .eq('hogar_id', hogarId)
    .order('dia_mes', { ascending: true });
  if (error) throw error;
  return data;
}

export async function agregarRecurrente(hogarId, campos) {
  const { data: usuario } = await supabase.auth.getUser();
  if (!usuario?.user) throw new Error('No hay sesión activa');

  const { data, error } = await supabase
    .from('servicios_recurrentes')
    .insert({
      hogar_id: hogarId,
      nombre: campos.nombre,
      categoria: campos.categoria || 'otros',
      monto: campos.monto,
      metodo_pago_id: campos.metodoPagoId || null,
      dia_mes: campos.diaMes,
      numero_referencia: campos.numeroReferencia || null,
      enlace_pago: campos.enlacePago || null,
      creado_por: usuario.user.id,
    })
    .select()
    .single();
  if (error) throw error;
  return data;
}

async function actualizarRecurrente(recurrenteId, cambios) {
  const { error } = await supabase.from('servicios_recurrentes').update(cambios).eq('id', recurrenteId);
  if (error) throw error;
}

export async function alternarActivoRecurrente(recurrenteId, activo) {
  await actualizarRecurrente(recurrenteId, { activo });
}

export async function eliminarRecurrente(recurrenteId) {
  const { error } = await supabase.from('servicios_recurrentes').delete().eq('id', recurrenteId);
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
 * Genera el pago pendiente del mes actual para cada plantilla activa que
 * todavía no lo tenga (botón "Generar pendientes del mes"). Devuelve cuántos
 * se crearon.
 */
export async function generarPendientesDelMes(hogarId) {
  const { data: usuario } = await supabase.auth.getUser();
  if (!usuario?.user) throw new Error('No hay sesión activa');

  const [recurrentes, serviciosExistentes] = await Promise.all([
    listarRecurrentes(hogarId),
    listarServicios(hogarId),
  ]);

  const activas = recurrentes.filter((r) => r.activo);
  const hoy = new Date();
  const mesActual = hoy.getMonth();
  const anioActual = hoy.getFullYear();

  const yaGenerados = new Set(
    serviciosExistentes
      .filter((s) => s.recurrente_id)
      .filter((s) => {
        const f = new Date(s.fecha_vencimiento + 'T00:00:00');
        return f.getMonth() === mesActual && f.getFullYear() === anioActual;
      })
      .map((s) => s.recurrente_id)
  );

  const pendientesPorCrear = activas.filter((r) => !yaGenerados.has(r.id));
  if (pendientesPorCrear.length === 0) return 0;

  const filas = pendientesPorCrear.map((r) => ({
    hogar_id: hogarId,
    nombre: r.nombre,
    categoria: r.categoria,
    monto: r.monto,
    metodo_pago_id: r.metodo_pago_id,
    fecha_vencimiento: fechaDelMes(r.dia_mes, hoy),
    numero_referencia: r.numero_referencia,
    enlace_pago: r.enlace_pago,
    recurrente_id: r.id,
    registrado_por: usuario.user.id,
  }));

  const { error } = await supabase.from('servicios_pagos').insert(filas);
  if (error) throw error;
  return filas.length;
}
