// ============================================================================
// DOMUS — Métodos de pago personales (billetera): saldo, ingresos, transferencias.
// 100% del usuario, no tiene relación con el hogar activo — ver sql/012.
// ============================================================================
import { supabase } from './supabaseClient.js';

async function usuarioActualId() {
  const { data: usuario } = await supabase.auth.getUser();
  if (!usuario?.user) throw new Error('No hay sesión activa');
  return usuario.user.id;
}

export const TIPOS_MOVIMIENTO = {
  ingreso: { etiqueta: 'Ingreso', signo: 1 },
  gasto: { etiqueta: 'Gasto', signo: -1 },
  transferencia_salida: { etiqueta: 'Transferencia enviada', signo: -1 },
  transferencia_entrada: { etiqueta: 'Transferencia recibida', signo: 1 },
};

export async function listarMetodos() {
  const usuarioId = await usuarioActualId();
  const { data, error } = await supabase
    .from('metodos_pago')
    .select('*')
    .eq('usuario_id', usuarioId)
    .order('created_at', { ascending: true });
  if (error) throw error;
  return data;
}

export async function crearMetodo(nombre, saldoInicial = 0) {
  const usuarioId = await usuarioActualId();
  const { data, error } = await supabase
    .from('metodos_pago')
    .insert({ usuario_id: usuarioId, nombre, saldo: saldoInicial || 0 })
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function renombrarMetodo(metodoId, nombre) {
  const { error } = await supabase.from('metodos_pago').update({ nombre }).eq('id', metodoId);
  if (error) throw error;
}

export async function eliminarMetodo(metodoId) {
  const { error } = await supabase.from('metodos_pago').delete().eq('id', metodoId);
  if (error) throw error;
}

/** Ingreso manual (te llegó dinero): suma al saldo y queda en el historial. */
export async function registrarIngreso(metodoId, monto, descripcion) {
  const { error } = await supabase.rpc('registrar_ingreso_metodo', {
    p_metodo_id: metodoId,
    p_monto: monto,
    p_descripcion: descripcion || null,
  });
  if (error) throw error;
}

/** Mueve dinero entre dos métodos propios de forma atómica (resta de uno, suma al otro). */
export async function transferir(origenId, destinoId, monto, descripcion) {
  const { error } = await supabase.rpc('transferir_entre_metodos', {
    p_origen_id: origenId,
    p_destino_id: destinoId,
    p_monto: monto,
    p_descripcion: descripcion || null,
  });
  if (error) throw error;
}

/** Historial combinado (todos los métodos), más reciente primero. */
export async function listarMovimientos(limite = 100) {
  const usuarioId = await usuarioActualId();
  const { data, error } = await supabase
    .from('metodo_pago_movimientos')
    .select('*, metodo:metodos_pago(id, nombre)')
    .eq('usuario_id', usuarioId)
    .order('created_at', { ascending: false })
    .limit(limite);
  if (error) throw error;
  return data;
}

export function calcularTotalSaldo(metodos) {
  return metodos.reduce((suma, m) => suma + Number(m.saldo), 0);
}
