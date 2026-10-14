# Santiago

Dinámica de la fiesta: "La foto con Santi". Los invitados suben su foto con el cumpleañero y votan; la foto con más likes gana.

- `index.html`: el sitio completo (estático).
- `supabase.sql`: tablas, permisos y almacenamiento. Se corre una vez en Supabase > SQL Editor.

## Funciones

- Subir foto (máximo 2 por celular) con mensaje opcional para Santi, y likes (uno por foto por dispositivo).
- Todo en vivo con Supabase Realtime: fotos, likes, podio y cambio de líder.
- Cuenta regresiva y cierre de votación: al cerrar se bloquean likes y subidas y aparece la foto ganadora.
- Pantalla grande para tele o proyector: agrega `?tv=1` a la dirección.
- Modo organizador (enlace "Organizador" al pie): cambiar la hora de cierre, cerrar o reabrir, borrar fotos y descargar el álbum en .zip.
  La contraseña la crea la primera persona que entra; para reiniciarla: `update public.fiesta_config set clave_hash = null;`
