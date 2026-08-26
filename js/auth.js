// ============================================================================
// DOMUS — Autenticación (registro, login, logout, recuperar contraseña)
// ============================================================================
import { supabase } from './supabaseClient.js';

/** Crea una cuenta nueva. El trigger handle_new_user (SQL) crea el perfil solo. */
export async function registrar(email, password, nombreCompleto) {
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      data: { nombre_completo: nombreCompleto },
    },
  });
  if (error) throw error;
  return data;
}

export async function iniciarSesion(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return data;
}

export async function cerrarSesion() {
  localStorage.removeItem('domus_hogar_activo');
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
}

/** Envía un correo con enlace para restablecer la contraseña. */
export async function solicitarRecuperacion(email) {
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    // Resuelve a la ruta correcta sin importar si el sitio vive en la raíz
    // del dominio o en un subdirectorio (típico de GitHub Pages: /domus/).
    redirectTo: new URL('nueva-password.html', window.location.href).toString(),
  });
  if (error) throw error;
}

/** Se usa en nueva-password.html, después de que el usuario llega desde el correo. */
export async function actualizarPassword(nuevaPassword) {
  const { error } = await supabase.auth.updateUser({ password: nuevaPassword });
  if (error) throw error;
}

export async function obtenerSesion() {
  const { data } = await supabase.auth.getSession();
  return data.session;
}

export async function obtenerUsuarioActual() {
  const { data } = await supabase.auth.getUser();
  return data.user;
}

/**
 * Guard de página: llama esto al inicio de cualquier página protegida.
 * Si no hay sesión, redirige a index.html (login) y detiene la ejecución.
 */
export async function protegerPagina() {
  const sesion = await obtenerSesion();
  if (!sesion) {
    window.location.href = 'index.html';
    return null;
  }
  return sesion;
}

export function escucharCambiosDeSesion(callback) {
  return supabase.auth.onAuthStateChange((_evento, sesion) => callback(sesion));
}
