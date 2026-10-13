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

-- Para ver al ganador:
--   select nombre, likes from public.fiesta_fotos order by likes desc, creado asc limit 5;
-- Para quitar una foto: bórrala en Table Editor > fiesta_fotos (y su archivo en Storage > fiesta-fotos).
