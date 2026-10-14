-- Dinámica "La foto con Santi"
-- Pégalo completo en Supabase > SQL Editor > Run (una sola vez).
-- No toca la tabla "Santi" de las confirmaciones.

-- 1) Fotos ------------------------------------------------------------------
create table if not exists public.fiesta_fotos (
  id        uuid primary key default gen_random_uuid(),
  creado    timestamptz not null default now(),
  nombre    text not null check (char_length(nombre) between 2 and 60),
  ruta      text not null unique check (ruta ~ '^[0-9a-f-]{36}\.jpg$'),
  device_id text not null check (char_length(device_id) between 10 and 64),
  likes     integer not null default 0
);

-- 2) Likes: la llave primaria impide dos likes del mismo dispositivo a la misma foto
create table if not exists public.fiesta_likes (
  foto_id   uuid not null references public.fiesta_fotos (id) on delete cascade,
  device_id text not null,
  creado    timestamptz not null default now(),
  primary key (foto_id, device_id)
);

alter table public.fiesta_fotos enable row level security;
alter table public.fiesta_likes enable row level security;

-- Los invitados pueden ver y subir fotos, pero no editar, borrar ni tocar el contador.
revoke all on public.fiesta_fotos from anon, authenticated;
revoke all on public.fiesta_likes from anon, authenticated;
grant select (id, creado, nombre, ruta, likes) on public.fiesta_fotos to anon, authenticated;
grant insert (nombre, ruta, device_id)         on public.fiesta_fotos to anon, authenticated;

drop policy if exists "fiesta ver fotos"   on public.fiesta_fotos;
drop policy if exists "fiesta subir fotos" on public.fiesta_fotos;
create policy "fiesta ver fotos"   on public.fiesta_fotos for select to anon, authenticated using (true);
create policy "fiesta subir fotos" on public.fiesta_fotos for insert to anon, authenticated with check (true);

-- 3) Dar / quitar like (única forma de modificar el contador) -----------------
create or replace function public.fiesta_like(p_foto uuid, p_device text)
returns table (total integer, me_gusta boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me_gusta boolean;
begin
  if p_device is null or char_length(p_device) not between 10 and 64 then
    raise exception 'dispositivo invalido';
  end if;

  delete from fiesta_likes l where l.foto_id = p_foto and l.device_id = p_device;
  if found then
    update fiesta_fotos f set likes = greatest(f.likes - 1, 0) where f.id = p_foto;
    v_me_gusta := false;
  else
    insert into fiesta_likes (foto_id, device_id) values (p_foto, p_device)
    on conflict do nothing;
    if found then
      update fiesta_fotos f set likes = f.likes + 1 where f.id = p_foto;
    end if;
    v_me_gusta := true;
  end if;

  return query select f.likes, v_me_gusta from fiesta_fotos f where f.id = p_foto;
end;
$$;

-- Fotos a las que este dispositivo ya les dio like
create or replace function public.fiesta_mis_likes(p_device text)
returns setof uuid
language sql
security definer
set search_path = public
as $$
  select l.foto_id from fiesta_likes l where l.device_id = p_device;
$$;

grant execute on function public.fiesta_like(uuid, text)  to anon, authenticated;
grant execute on function public.fiesta_mis_likes(text)   to anon, authenticated;

-- 4) Almacenamiento de las imágenes -----------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fiesta-fotos', 'fiesta-fotos', true, 5242880, array['image/jpeg'])
on conflict (id) do nothing;

drop policy if exists "fiesta subir imagen" on storage.objects;
create policy "fiesta subir imagen" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'fiesta-fotos');

-- 5) Tiempo real: avisa al sitio de cada foto y cada like al instante ----------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'fiesta_fotos') then
    alter publication supabase_realtime add table public.fiesta_fotos;
  end if;
end $$;

-- 6) Mensaje para Santi -------------------------------------------------------
alter table public.fiesta_fotos add column if not exists mensaje text;
alter table public.fiesta_fotos drop constraint if exists fiesta_fotos_mensaje_largo;
alter table public.fiesta_fotos add constraint fiesta_fotos_mensaje_largo check (mensaje is null or char_length(mensaje) <= 140);
grant select (mensaje) on public.fiesta_fotos to anon, authenticated;
grant insert (mensaje) on public.fiesta_fotos to anon, authenticated;

-- 7) Configuración: hora de cierre y contraseña del organizador (solo su hash) --
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.fiesta_config (
  id         integer primary key default 1 check (id = 1),
  cierre     timestamptz,
  clave_hash text
);
-- Cierre inicial: viernes 16 de octubre, 6:00 PM hora de Cancún. Se cambia desde el modo organizador.
insert into public.fiesta_config (id, cierre) values (1, '2026-10-16 18:00:00-05')
on conflict (id) do nothing;

alter table public.fiesta_config enable row level security;
revoke all on public.fiesta_config from anon, authenticated;
grant select (id, cierre) on public.fiesta_config to anon, authenticated;   -- el hash nunca sale
drop policy if exists "fiesta ver config" on public.fiesta_config;
create policy "fiesta ver config" on public.fiesta_config for select to anon, authenticated using (true);

create or replace function public.fiesta_cerrada()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select c.cierre <= now() from fiesta_config c where c.id = 1), false);
$$;

-- 8) Al subir: votación abierta y máximo 2 fotos por dispositivo ----------------
create or replace function public.fiesta_antes_de_subir()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if fiesta_cerrada() then
    raise exception 'votacion cerrada';
  end if;
  if (select count(*) from fiesta_fotos f where f.device_id = new.device_id) >= 2 then
    raise exception 'limite de fotos';
  end if;
  new.likes := 0;
  return new;
end;
$$;
drop trigger if exists fiesta_antes_de_subir on public.fiesta_fotos;
create trigger fiesta_antes_de_subir before insert on public.fiesta_fotos
  for each row execute function public.fiesta_antes_de_subir();

create or replace function public.fiesta_mis_fotos(p_device text)
returns setof uuid language sql security definer set search_path = public as $$
  select f.id from fiesta_fotos f where f.device_id = p_device;
$$;

-- Los likes se bloquean al cerrar la votación
create or replace function public.fiesta_like(p_foto uuid, p_device text)
returns table (total integer, me_gusta boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me_gusta boolean;
begin
  if p_device is null or char_length(p_device) not between 10 and 64 then
    raise exception 'dispositivo invalido';
  end if;
  if fiesta_cerrada() then
    raise exception 'votacion cerrada';
  end if;

  delete from fiesta_likes l where l.foto_id = p_foto and l.device_id = p_device;
  if found then
    update fiesta_fotos f set likes = greatest(f.likes - 1, 0) where f.id = p_foto;
    v_me_gusta := false;
  else
    insert into fiesta_likes (foto_id, device_id) values (p_foto, p_device)
    on conflict do nothing;
    if found then
      update fiesta_fotos f set likes = f.likes + 1 where f.id = p_foto;
    end if;
    v_me_gusta := true;
  end if;

  return query select f.likes, v_me_gusta from fiesta_fotos f where f.id = p_foto;
end;
$$;

-- 9) Modo organizador -----------------------------------------------------------
create or replace function public.fiesta_admin_existe()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from fiesta_config c where c.id = 1 and c.clave_hash is not null);
$$;

-- La primera persona que entra al modo organizador crea la contraseña; después ya no se puede.
-- Para reiniciarla: update public.fiesta_config set clave_hash = null;
create or replace function public.fiesta_admin_crear(p_clave text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_clave is null or char_length(p_clave) < 6 or char_length(p_clave) > 72 then
    raise exception 'clave muy corta';
  end if;
  update fiesta_config c set clave_hash = crypt(p_clave, gen_salt('bf')) where c.id = 1 and c.clave_hash is null;
  if not found then
    raise exception 'ya existe una clave';
  end if;
  return true;
end;
$$;

create or replace function public.fiesta_admin_valida(p_clave text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare
  v_hash text;
begin
  select c.clave_hash into v_hash from fiesta_config c where c.id = 1;
  if v_hash is not null and p_clave is not null and v_hash = crypt(p_clave, v_hash) then
    return true;
  end if;
  perform pg_sleep(1);   -- frena los intentos de adivinarla
  return false;
end;
$$;

create or replace function public.fiesta_admin_borrar(p_clave text, p_foto uuid)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  if not fiesta_admin_valida(p_clave) then raise exception 'clave incorrecta'; end if;
  delete from fiesta_fotos f where f.id = p_foto;
  return found;
end;
$$;

-- p_cierre nulo = votación sin hora de cierre (abierta)
create or replace function public.fiesta_admin_cierre(p_clave text, p_cierre timestamptz)
returns timestamptz language plpgsql security definer set search_path = public, extensions as $$
begin
  if not fiesta_admin_valida(p_clave) then raise exception 'clave incorrecta'; end if;
  update fiesta_config c set cierre = p_cierre where c.id = 1;
  return p_cierre;
end;
$$;

grant execute on function public.fiesta_cerrada(), public.fiesta_mis_fotos(text), public.fiesta_admin_existe(),
  public.fiesta_admin_crear(text), public.fiesta_admin_valida(text), public.fiesta_admin_borrar(text, uuid),
  public.fiesta_admin_cierre(text, timestamptz) to anon, authenticated;
revoke execute on function public.fiesta_antes_de_subir() from anon, authenticated, public;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'fiesta_config') then
    alter publication supabase_realtime add table public.fiesta_config;
  end if;
end $$;

-- Para ver al ganador:
--   select nombre, likes from public.fiesta_fotos order by likes desc, creado asc limit 5;
-- Para quitar una foto: bórrala en Table Editor > fiesta_fotos (y su archivo en Storage > fiesta-fotos).
