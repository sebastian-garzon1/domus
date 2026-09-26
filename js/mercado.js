// ============================================================================
// DOMUS — Mercado y lista de compras compartida del hogar
// ============================================================================
import { supabase } from './supabaseClient.js';

/** Catálogo de categorías (debe coincidir con el CHECK de sql/002_mercado.sql). */
export const CATEGORIAS = [
  { valor: 'despensa', etiqueta: 'Despensa' },
  { valor: 'lacteos_huevos', etiqueta: 'Lácteos y huevos' },
  { valor: 'carnes_pescado', etiqueta: 'Carnes y pescado' },
  { valor: 'frutas_verduras', etiqueta: 'Frutas y verduras' },
  { valor: 'panaderia', etiqueta: 'Panadería' },
  { valor: 'bebidas', etiqueta: 'Bebidas' },
  { valor: 'aseo_hogar', etiqueta: 'Aseo del hogar' },
  { valor: 'cuidado_personal', etiqueta: 'Cuidado personal' },
  { valor: 'mascotas', etiqueta: 'Mascotas' },
  { valor: 'otros', etiqueta: 'Otros' },
];

/** Catálogo de unidades (debe coincidir con el CHECK de sql/002_mercado.sql). */
export const UNIDADES = ['unidad', 'kg', 'g', 'l', 'ml', 'paquete', 'docena', 'caja'];

export const PRIORIDADES = [
  { valor: 'alta', etiqueta: 'Alta', clase: 'text-bg-danger' },
  { valor: 'media', etiqueta: 'Media', clase: 'text-bg-warning' },
  { valor: 'baja', etiqueta: 'Baja', clase: 'text-bg-secondary' },
];

export function etiquetaCategoria(valor) {
  return CATEGORIAS.find((c) => c.valor === valor)?.etiqueta ?? valor;
}

export function prioridadInfo(valor) {
  return PRIORIDADES.find((p) => p.valor === valor) ?? PRIORIDADES[1];
}

// Los dos FK de mercado_items hacia profiles (agregado_por, comprado_por) son
// ambiguos para PostgREST si no se indica cuál usar: hay que nombrar la
// relación explícitamente con el nombre de la constraint que genera Postgres
// por convención (<tabla>_<columna>_fkey).
const SELECT_ITEM = `
  *,
  agregado_por_perfil:profiles!mercado_items_agregado_por_fkey (id, nombre_completo, email),
  comprado_por_perfil:profiles!mercado_items_comprado_por_fkey (id, nombre_completo, email),
  metodo_pago:metodos_pago (id, nombre)
`;

/** Lista todos los ítems de mercado de un hogar (pendientes y comprados). */
export async function listarItems(hogarId) {
  const { data, error } = await supabase
    .from('mercado_items')
    .select(SELECT_ITEM)
    .eq('hogar_id', hogarId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return data;
}

/** Agrega un ítem nuevo a la lista. Queda "pendiente" por defecto. */
export async function agregarItem(hogarId, campos) {
  const { data: usuario } = await supabase.auth.getUser();
  if (!usuario?.user) throw new Error('No hay sesión activa');

  const { data, error } = await supabase
    .from('mercado_items')
    .insert({
      hogar_id: hogarId,
      nombre: campos.nombre,
      categoria: campos.categoria || 'otros',
      cantidad: campos.cantidad || 1,
      unidad: campos.unidad || 'unidad',
      prioridad: campos.prioridad || 'media',
      precio_estimado: campos.precioEstimado || null,
      observaciones: campos.observaciones || null,
      agregado_por: usuario.user.id,
    })
    .select(SELECT_ITEM)
    .single();
  if (error) throw error;
  return data;
}

export async function actualizarItem(itemId, cambios) {
  const { error } = await supabase.from('mercado_items').update(cambios).eq('id', itemId);
  if (error) throw error;
}

/**
 * Marca un ítem como comprado. precioFinal es opcional (queda en null si no
 * se indica, se usa precio_estimado). metodoPagoId es opcional: con qué
 * método personal se pagó (descuenta su saldo, ver sql/012).
 */
export async function marcarComprado(itemId, precioFinal, metodoPagoId) {
  const cambios = { estado: 'comprado' };
  if (precioFinal !== undefined && precioFinal !== null && precioFinal !== '') {
    cambios.precio_final = precioFinal;
  }
  if (metodoPagoId) cambios.metodo_pago_id = metodoPagoId;
  await actualizarItem(itemId, cambios);
}

/** Reabre un ítem ya comprado (vuelve a "pendiente"; el trigger limpia comprado_por/comprado_en). */
export async function reabrirItem(itemId) {
  await actualizarItem(itemId, { estado: 'pendiente' });
}

export async function eliminarItem(itemId) {
  const { error } = await supabase.from('mercado_items').delete().eq('id', itemId);
  if (error) throw error;
}

/** Calcula los totales que se muestran en el resumen del módulo. */
export function calcularTotales(items) {
  const ahora = new Date();
  const totales = {
    totalEstimadoPendientes: 0,
    countPendientes: 0,
    totalGastadoMes: 0,
    countCompradosMes: 0,
  };

  for (const item of items) {
    if (item.estado === 'pendiente') {
      totales.totalEstimadoPendientes += Number(item.precio_estimado || 0);
      totales.countPendientes += 1;
    } else if (item.estado === 'comprado' && item.comprado_en) {
      const fecha = new Date(item.comprado_en);
      if (fecha.getFullYear() === ahora.getFullYear() && fecha.getMonth() === ahora.getMonth()) {
        totales.totalGastadoMes += Number(item.precio_final ?? item.precio_estimado ?? 0);
        totales.countCompradosMes += 1;
      }
    }
  }
  return totales;
}
