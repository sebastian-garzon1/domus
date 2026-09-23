// ============================================================================
// DOMUS — Gestión de hogares (crear, listar, seleccionar, invitar miembros)
// ============================================================================
import { supabase } from './supabaseClient.js';

const CLAVE_HOGAR_ACTIVO = 'domus_hogar_activo';

/** Lista los hogares a los que pertenece el usuario autenticado, con su rol. */
export async function listarMisHogares() {
  const { data, error } = await supabase
    .from('hogar_miembros')
    .select('rol, hogar:hogares(id, nombre, descripcion, presupuesto_mensual, creado_por)')
    .order('unido_en', { ascending: true });
  if (error) throw error;
  return data.map((fila) => ({ ...fila.hogar, mi_rol: fila.rol }));
}

/** Crea un hogar nuevo. El usuario actual queda como administrador automáticamente. */
export async function crearHogar({ nombre, descripcion = '', presupuestoMensual = 0 }) {
  const { data: usuario } = await supabase.auth.getUser();
  if (!usuario?.user) throw new Error('No hay sesión activa');

  const { data, error } = await supabase
    .from('hogares')
    .insert({
      nombre,
      descripcion,
      presupuesto_mensual: presupuestoMensual,
      creado_por: usuario.user.id,
    })
    .select()
    .single();

  if (error) throw error;
  return data;
}

/** Lista los miembros de un hogar (requiere pertenecer a él, por RLS). */
export async function listarMiembros(hogarId) {
  const { data, error } = await supabase
    .from('hogar_miembros')
    .select('rol, unido_en, perfil:profiles(id, email, nombre_completo, avatar_url)')
    .eq('hogar_id', hogarId);
  if (error) throw error;
  return data;
}

/**
 * Invita a alguien por correo a un hogar. Si ya tiene cuenta en Domus queda
 * agregado de inmediato; si no, queda pendiente hasta que se registre.
 * Devuelve 'agregado_directamente' o 'invitacion_pendiente'.
 */
export async function invitarMiembro(hogarId, email, rol = 'miembro') {
  const { data, error } = await supabase.rpc('invitar_miembro', {
    p_hogar_id: hogarId,
    p_email: email,
    p_rol: rol,
  });
  if (error) throw error;
  return data;
}

export async function cambiarRolMiembro(hogarId, usuarioId, nuevoRol) {
  const { error } = await supabase
    .from('hogar_miembros')
    .update({ rol: nuevoRol })
    .eq('hogar_id', hogarId)
    .eq('usuario_id', usuarioId);
  if (error) throw error;
}

/** Quita a un miembro del hogar (o permite que uno mismo se salga). */
export async function eliminarMiembro(hogarId, usuarioId) {
  const { error } = await supabase
    .from('hogar_miembros')
    .delete()
    .eq('hogar_id', hogarId)
    .eq('usuario_id', usuarioId);
  if (error) throw error;
}

export async function actualizarHogar(hogarId, cambios) {
  const { error } = await supabase.from('hogares').update(cambios).eq('id', hogarId);
  if (error) throw error;
}

// --- Hogar activo (cuál está viendo el usuario ahora mismo) ----------------

export function obtenerHogarActivoId() {
  return localStorage.getItem(CLAVE_HOGAR_ACTIVO);
}

export function fijarHogarActivo(hogarId) {
  localStorage.setItem(CLAVE_HOGAR_ACTIVO, hogarId);
}

export function limpiarHogarActivo() {
  localStorage.removeItem(CLAVE_HOGAR_ACTIVO);
}

/**
 * Devuelve el hogar activo verificando que el usuario siga perteneciendo a él.
 * Si no hay hogar activo válido, devuelve null (la página debe mandar a hogares/).
 */
export async function obtenerHogarActivoValidado() {
  const hogarId = obtenerHogarActivoId();
  if (!hogarId) return null;

  const misHogares = await listarMisHogares();
  const hogar = misHogares.find((h) => h.id === hogarId);
  if (!hogar) {
    limpiarHogarActivo();
    return null;
  }
  return hogar;
}
