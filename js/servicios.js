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
  pagado_por_perfil:profiles!servicios_pagos_pagado_por_fkey (id, nombre_completo, email)
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

export async function marcarPagado(servicioId) {
  await actualizarServicio(servicioId, { estado: 'pagado' });
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

export async function eliminarComprobante(servicioId, path) {
  const { error } = await supabase.storage.from(BUCKET).remove([path]);
  if (error) throw error;
  await actualizarServicio(servicioId, { comprobante_path: null });
}

/** Resumen para el dashboard y las tarjetas de servicios.html. */
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
  };
}
