-- ============================================================
-- Gestión: licitaciones privadas, obra, inventario, caja chica y facturación.
-- Requiere 0001 (profiles, current_user_role, set_updated_at) y 0002 (oportunidades).
-- ============================================================

do $$ begin
  create type public.origen_proyecto as enum ('publica','privada','directa');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.estado_proyecto as enum
    ('planificacion','en_ejecucion','suspendido','terminado','liquidado','cancelado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.estado_cubicacion as enum
    ('borrador','presentada','aprobada','rechazada','facturada');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.tipo_articulo as enum ('material','equipo','herramienta','consumible');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.tipo_movimiento as enum ('entrada','salida','traslado','ajuste','devolucion');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.estado_factura as enum
    ('borrador','emitida','enviada','cobrada','anulada','rechazada');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- Licitaciones privadas — módulo SEPARADO del público: llegan por invitación
-- directa, sin portal ni pliego estándar.
-- ------------------------------------------------------------
create table if not exists public.licitaciones_privadas (
  id                uuid primary key default gen_random_uuid(),
  codigo            text unique,
  cliente           text not null,
  contacto          text,
  correo_contacto   text,
  telefono_contacto text,
  titulo            text not null,
  descripcion       text,
  ubicacion         text,
  monto_estimado    numeric,
  divisa            text not null default 'DOP',
  fecha_invitacion  date,
  fecha_entrega     timestamptz,
  estado            public.oportunidad_estado not null default 'nueva',
  responsable       uuid references auth.users(id) on delete set null,
  monto_ofertado    numeric,
  motivo_descarte   text,
  notas             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table public.licitaciones_privadas is
  'Licitaciones del sector privado: invitación directa, sin portal ni pliego estándar.';
create index if not exists licitaciones_privadas_estado_idx on public.licitaciones_privadas (estado);

drop trigger if exists set_updated_at on public.licitaciones_privadas;
create trigger set_updated_at before update on public.licitaciones_privadas
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- Proyectos: una licitación ganada (pública o privada) se vuelve obra.
-- ------------------------------------------------------------
create table if not exists public.proyectos (
  id                    uuid primary key default gen_random_uuid(),
  codigo                text unique not null,
  nombre                text not null,
  origen                public.origen_proyecto not null,
  oportunidad_id        uuid references public.oportunidades(id) on delete set null,
  licitacion_privada_id uuid references public.licitaciones_privadas(id) on delete set null,
  cliente               text not null,
  ubicacion             text,
  monto_contratado      numeric,
  divisa                text not null default 'DOP',
  fecha_inicio          date,
  fecha_fin_prevista    date,
  fecha_fin_real        date,
  estado                public.estado_proyecto not null default 'planificacion',
  responsable           uuid references auth.users(id) on delete set null,
  notas                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint proyecto_un_solo_origen check (
    (oportunidad_id is null) or (licitacion_privada_id is null)
  )
);
comment on table public.proyectos is 'Obras en ejecución. Se crean desde una licitación ganada.';
create index if not exists proyectos_estado_idx      on public.proyectos (estado);
create index if not exists proyectos_responsable_idx on public.proyectos (responsable);

drop trigger if exists set_updated_at on public.proyectos;
create trigger set_updated_at before update on public.proyectos
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- Presupuesto por partidas. El monto es calculado, nunca se teclea.
-- ------------------------------------------------------------
create table if not exists public.partidas (
  id              uuid primary key default gen_random_uuid(),
  proyecto_id     uuid not null references public.proyectos(id) on delete cascade,
  codigo          text,
  descripcion     text not null,
  unidad          text not null,          -- m2, m3, ml, ud, qq...
  cantidad        numeric not null default 0,
  precio_unitario numeric not null default 0,
  monto           numeric generated always as (cantidad * precio_unitario) stored,
  orden           integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (proyecto_id, codigo)
);
comment on table public.partidas is 'Partidas del presupuesto de una obra. El monto es calculado.';
create index if not exists partidas_proyecto_idx on public.partidas (proyecto_id);

drop trigger if exists set_updated_at on public.partidas;
create trigger set_updated_at before update on public.partidas
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- Cubicaciones: el avance que se mide, se aprueba y se factura.
-- ------------------------------------------------------------
create table if not exists public.cubicaciones (
  id                 uuid primary key default gen_random_uuid(),
  proyecto_id        uuid not null references public.proyectos(id) on delete cascade,
  numero             integer not null,
  periodo_desde      date,
  periodo_hasta      date,
  estado             public.estado_cubicacion not null default 'borrador',
  fecha_presentacion date,
  fecha_aprobacion   date,
  aprobada_por       uuid references auth.users(id) on delete set null,
  notas              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (proyecto_id, numero)
);
comment on table public.cubicaciones is
  'Medición de avance por período. Una cubicación aprobada es lo que se factura.';
create index if not exists cubicaciones_proyecto_idx on public.cubicaciones (proyecto_id, numero);

drop trigger if exists set_updated_at on public.cubicaciones;
create trigger set_updated_at before update on public.cubicaciones
  for each row execute function public.set_updated_at();

create table if not exists public.cubicacion_partidas (
  id            uuid primary key default gen_random_uuid(),
  cubicacion_id uuid not null references public.cubicaciones(id) on delete cascade,
  partida_id    uuid not null references public.partidas(id) on delete cascade,
  cantidad      numeric not null default 0,
  unique (cubicacion_id, partida_id)
);
comment on table public.cubicacion_partidas is 'Cantidad ejecutada de cada partida en una cubicación.';
create index if not exists cubicacion_partidas_cub_idx on public.cubicacion_partidas (cubicacion_id);

create table if not exists public.subcontratos (
  id             uuid primary key default gen_random_uuid(),
  proyecto_id    uuid not null references public.proyectos(id) on delete cascade,
  subcontratista text not null,
  rnc            text,
  alcance        text not null,
  monto          numeric,
  fecha_inicio   date,
  fecha_fin      date,
  estado         text not null default 'vigente',
  notas          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table public.subcontratos is 'Trabajos contratados a terceros dentro de una obra.';
create index if not exists subcontratos_proyecto_idx on public.subcontratos (proyecto_id);

drop trigger if exists set_updated_at on public.subcontratos;
create trigger set_updated_at before update on public.subcontratos
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- Inventario
-- ------------------------------------------------------------
create table if not exists public.almacenes (
  id          uuid primary key default gen_random_uuid(),
  nombre      text not null,
  proyecto_id uuid references public.proyectos(id) on delete cascade,
  ubicacion   text,
  encargado   uuid references auth.users(id) on delete set null,
  activo      boolean not null default true,
  created_at  timestamptz not null default now()
);
comment on column public.almacenes.proyecto_id is 'null = almacén central; con valor = almacén de esa obra.';

create table if not exists public.articulos (
  id               uuid primary key default gen_random_uuid(),
  codigo           text unique not null,
  descripcion      text not null,
  tipo             public.tipo_articulo not null default 'material',
  unidad           text not null,          -- qq, m3, ud, saco, galón...
  stock_minimo     numeric not null default 0,
  costo_referencia numeric,
  activo           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on table public.articulos is 'Catálogo de materiales, equipos y herramientas.';

drop trigger if exists set_updated_at on public.articulos;
create trigger set_updated_at before update on public.articulos
  for each row execute function public.set_updated_at();

-- El stock NO se guarda: se calcula desde los movimientos. Así no se
-- desincroniza nunca y siempre queda el rastro de quién movió qué.
create table if not exists public.movimientos_inventario (
  id                 bigserial primary key,
  articulo_id        uuid not null references public.articulos(id) on delete restrict,
  almacen_id         uuid not null references public.almacenes(id) on delete restrict,
  tipo               public.tipo_movimiento not null,
  cantidad           numeric not null,
  costo_unitario     numeric,
  proyecto_id        uuid references public.proyectos(id) on delete set null,
  almacen_destino_id uuid references public.almacenes(id) on delete set null,
  referencia         text,          -- factura de compra, requisición...
  entregado_a        text,
  registrado_por     uuid references auth.users(id) on delete set null,
  fecha              timestamptz not null default now(),
  notas              text,
  constraint cantidad_positiva check (cantidad > 0),
  constraint traslado_tiene_destino check (tipo <> 'traslado' or almacen_destino_id is not null)
);
comment on table public.movimientos_inventario is
  'Toda entrada y salida de almacén. El stock se deriva de aquí, nunca se edita a mano.';
create index if not exists movimientos_articulo_idx on public.movimientos_inventario (articulo_id, fecha desc);
create index if not exists movimientos_almacen_idx  on public.movimientos_inventario (almacen_id);
create index if not exists movimientos_proyecto_idx on public.movimientos_inventario (proyecto_id);

-- ------------------------------------------------------------
-- Caja chica
-- ------------------------------------------------------------
create table if not exists public.cajas_chicas (
  id             uuid primary key default gen_random_uuid(),
  nombre         text not null,
  proyecto_id    uuid references public.proyectos(id) on delete cascade,
  responsable    uuid references auth.users(id) on delete set null,
  fondo_asignado numeric not null default 0,
  activa         boolean not null default true,
  created_at     timestamptz not null default now()
);
comment on table public.cajas_chicas is 'Fondo fijo por obra o área. El saldo se calcula desde los movimientos.';

create table if not exists public.movimientos_caja (
  id             bigserial primary key,
  caja_id        uuid not null references public.cajas_chicas(id) on delete cascade,
  tipo           text not null check (tipo in ('gasto','reposicion','ajuste')),
  monto          numeric not null check (monto > 0),
  concepto       text not null,
  categoria      text,
  comprobante    text,          -- NCF o número de recibo
  proveedor      text,
  fecha          date not null default current_date,
  registrado_por uuid references auth.users(id) on delete set null,
  adjunto_url    text,
  created_at     timestamptz not null default now()
);
create index if not exists movimientos_caja_idx on public.movimientos_caja (caja_id, fecha desc);

-- ------------------------------------------------------------
-- Facturación electrónica (e-CF, Ley 32-23)
-- ------------------------------------------------------------
create table if not exists public.facturas (
  id                uuid primary key default gen_random_uuid(),
  numero_interno    text unique not null,
  proyecto_id       uuid references public.proyectos(id) on delete set null,
  cubicacion_id     uuid references public.cubicaciones(id) on delete set null,
  cliente           text not null,
  rnc_cliente       text,
  tipo_ecf          text,   -- 31 crédito fiscal, 32 consumo, 34 nota de crédito...
  ncf               text unique,
  fecha_emision     date not null default current_date,
  fecha_vencimiento date,
  divisa            text not null default 'DOP',
  subtotal          numeric not null default 0,
  itbis             numeric not null default 0,
  retencion         numeric not null default 0,
  total             numeric generated always as (subtotal + itbis - retencion) stored,
  estado            public.estado_factura not null default 'borrador',
  ecf_estado        text,
  ecf_track_id      text,
  ecf_respuesta     jsonb,
  ecf_enviada_en    timestamptz,
  notas             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table public.facturas is
  'Facturas de JMC. Los campos ecf_* guardan el acuse de la DGII (Ley 32-23, obligatorio 15-nov-2026).';
create index if not exists facturas_proyecto_idx on public.facturas (proyecto_id);
create index if not exists facturas_estado_idx   on public.facturas (estado);

drop trigger if exists set_updated_at on public.facturas;
create trigger set_updated_at before update on public.facturas
  for each row execute function public.set_updated_at();

create table if not exists public.factura_lineas (
  id              uuid primary key default gen_random_uuid(),
  factura_id      uuid not null references public.facturas(id) on delete cascade,
  descripcion     text not null,
  unidad          text,
  cantidad        numeric not null default 1,
  precio_unitario numeric not null default 0,
  monto           numeric generated always as (cantidad * precio_unitario) stored,
  tasa_itbis      numeric not null default 18,   -- % ITBIS vigente en RD
  orden           integer not null default 0
);
create index if not exists factura_lineas_factura_idx on public.factura_lineas (factura_id);

-- ============================================================
-- Permisos por rol
-- ============================================================
create or replace function public.rol_es(variadic roles public.user_role[])
returns boolean language sql stable security definer
set search_path = public, pg_temp
as $$ select public.current_user_role() = any(roles) $$;

revoke execute on function public.rol_es(public.user_role[]) from public;
grant  execute on function public.rol_es(public.user_role[]) to authenticated;

-- Leer puede todo el que inicie sesión; escribir, solo el rol que corresponde.
do $$
declare
  t text; roles text[];
  escritura jsonb := jsonb_build_object(
    'licitaciones_privadas',  array['administrador','director','gerente_licitaciones'],
    'proyectos',              array['administrador','director','ingenieria'],
    'partidas',               array['administrador','director','presupuesto','ingenieria'],
    'cubicaciones',           array['administrador','director','presupuesto','ingenieria'],
    'cubicacion_partidas',    array['administrador','director','presupuesto','ingenieria'],
    'subcontratos',           array['administrador','director','ingenieria','compras'],
    'almacenes',              array['administrador','director','compras','ingenieria'],
    'articulos',              array['administrador','director','compras'],
    'movimientos_inventario', array['administrador','director','compras','ingenieria'],
    'cajas_chicas',           array['administrador','director','finanzas'],
    'movimientos_caja',       array['administrador','director','finanzas'],
    'facturas',               array['administrador','director','finanzas'],
    'factura_lineas',         array['administrador','director','finanzas']
  );
begin
  for t in select jsonb_object_keys(escritura) loop
    roles := array(select jsonb_array_elements_text(escritura -> t));
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_lectura', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)',
                   t || '_lectura', t);
    execute format('drop policy if exists %I on public.%I', t || '_escritura', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (public.rol_es(variadic %L::public.user_role[]))
         with check (public.rol_es(variadic %L::public.user_role[]))',
      t || '_escritura', t, roles, roles);
  end loop;
end $$;

-- ============================================================
-- Vistas
-- ============================================================

-- Existencia por artículo y almacén, derivada de los movimientos.
create or replace view public.v_stock
with (security_invoker = true) as
with saldos as (
  select articulo_id, almacen_id,
         sum(case when tipo in ('entrada','devolucion') then cantidad
                  when tipo = 'salida'                  then -cantidad
                  when tipo = 'ajuste'                  then cantidad
                  when tipo = 'traslado'                then -cantidad end) as cantidad
  from public.movimientos_inventario group by 1,2
  union all
  select articulo_id, almacen_destino_id, sum(cantidad)
  from public.movimientos_inventario
  where tipo = 'traslado' and almacen_destino_id is not null
  group by 1,2
)
select
  a.id as articulo_id, a.codigo, a.descripcion, a.tipo, a.unidad, a.stock_minimo,
  al.id as almacen_id, al.nombre as almacen, al.proyecto_id,
  sum(s.cantidad) as existencia,
  (sum(s.cantidad) < a.stock_minimo) as bajo_minimo
from saldos s
join public.articulos a  on a.id  = s.articulo_id
join public.almacenes al on al.id = s.almacen_id
group by a.id, a.codigo, a.descripcion, a.tipo, a.unidad, a.stock_minimo,
         al.id, al.nombre, al.proyecto_id;
comment on view public.v_stock is 'Existencia por artículo y almacén, calculada desde los movimientos.';

create or replace view public.v_caja_saldo
with (security_invoker = true) as
select
  c.id as caja_id, c.nombre, c.proyecto_id, c.responsable, c.fondo_asignado,
  coalesce(sum(m.monto) filter (where m.tipo = 'reposicion'), 0) as repuesto,
  coalesce(sum(m.monto) filter (where m.tipo = 'gasto'),      0) as gastado,
  c.fondo_asignado
    + coalesce(sum(m.monto) filter (where m.tipo = 'reposicion'), 0)
    - coalesce(sum(m.monto) filter (where m.tipo = 'gasto'),      0)
    + coalesce(sum(m.monto) filter (where m.tipo = 'ajuste'),     0) as saldo
from public.cajas_chicas c
left join public.movimientos_caja m on m.caja_id = c.id
group by c.id, c.nombre, c.proyecto_id, c.responsable, c.fondo_asignado;
comment on view public.v_caja_saldo is 'Saldo disponible de cada caja chica.';

-- Presupuestado contra ejecutado: el margen real de cada obra.
create or replace view public.v_obra_avance
with (security_invoker = true) as
select
  p.id as proyecto_id, p.codigo, p.nombre, p.cliente, p.estado,
  p.monto_contratado,
  coalesce(pres.presupuestado, 0) as presupuestado,
  coalesce(ejec.ejecutado, 0)     as ejecutado,
  case when coalesce(pres.presupuestado,0) > 0
       then round(100.0 * coalesce(ejec.ejecutado,0) / pres.presupuestado, 1) end as avance_pct,
  coalesce(fact.facturado, 0)         as facturado,
  coalesce(mat.consumo_materiales, 0) as consumo_materiales,
  coalesce(caja.gastos_caja, 0)       as gastos_caja,
  coalesce(sub.subcontratado, 0)      as subcontratado,
  p.monto_contratado
    - coalesce(mat.consumo_materiales,0)
    - coalesce(caja.gastos_caja,0)
    - coalesce(sub.subcontratado,0)   as margen_estimado
from public.proyectos p
left join lateral (
  select sum(monto) as presupuestado from public.partidas where proyecto_id = p.id
) pres on true
left join lateral (
  select sum(cp.cantidad * pa.precio_unitario) as ejecutado
  from public.cubicacion_partidas cp
  join public.cubicaciones c on c.id = cp.cubicacion_id
  join public.partidas pa    on pa.id = cp.partida_id
  where c.proyecto_id = p.id and c.estado in ('aprobada','facturada')
) ejec on true
left join lateral (
  select sum(total) as facturado from public.facturas
  where proyecto_id = p.id and estado <> 'anulada'
) fact on true
left join lateral (
  select sum(cantidad * coalesce(costo_unitario,0)) as consumo_materiales
  from public.movimientos_inventario
  where proyecto_id = p.id and tipo = 'salida'
) mat on true
left join lateral (
  select sum(m.monto) as gastos_caja
  from public.movimientos_caja m
  join public.cajas_chicas cc on cc.id = m.caja_id
  where cc.proyecto_id = p.id and m.tipo = 'gasto'
) caja on true
left join lateral (
  select sum(monto) as subcontratado from public.subcontratos where proyecto_id = p.id
) sub on true;
comment on view public.v_obra_avance is
  'Presupuestado vs ejecutado vs facturado por obra, con margen estimado descontando materiales, caja y subcontratos.';

grant select on public.v_stock       to authenticated;
grant select on public.v_caja_saldo  to authenticated;
grant select on public.v_obra_avance to authenticated;

-- ============================================================
-- El puente entre licitar y ejecutar: una licitación ganada se vuelve obra
-- arrastrando lo que ya se sabe, sin volver a teclear nada.
-- ============================================================
create or replace function public.crear_obra_desde_oportunidad(
  p_oportunidad uuid,
  p_codigo text default null,
  p_monto_contratado numeric default null
)
returns uuid language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_id uuid; o record;
begin
  if not public.rol_es('administrador','director','ingenieria','gerente_licitaciones') then
    raise exception 'No tienes permiso para crear obras';
  end if;

  select o.id, o.estado, o.monto_ofertado, p.codigo_proceso, p.titulo,
         p.monto_estimado, p.duracion_contrato, p.unidad_compra
  into o
  from public.oportunidades o
  join public.dgcp_procesos p on p.codigo_proceso = o.codigo_proceso
  where o.id = p_oportunidad;

  if not found then
    raise exception 'La oportunidad % no existe', p_oportunidad;
  end if;
  if o.estado <> 'ganada' then
    raise exception 'La oportunidad está en estado "%": solo se crea la obra cuando está ganada', o.estado;
  end if;
  if exists (select 1 from public.proyectos where oportunidad_id = p_oportunidad) then
    raise exception 'Esa oportunidad ya tiene una obra creada';
  end if;

  insert into public.proyectos (
    codigo, nombre, origen, oportunidad_id, cliente, monto_contratado, estado, responsable)
  values (
    coalesce(p_codigo, o.codigo_proceso), o.titulo, 'publica', p_oportunidad,
    o.unidad_compra, coalesce(p_monto_contratado, o.monto_ofertado, o.monto_estimado),
    'planificacion', auth.uid())
  returning id into v_id;

  return v_id;
end $$;

create or replace function public.crear_obra_desde_privada(
  p_licitacion uuid,
  p_codigo text default null,
  p_monto_contratado numeric default null
)
returns uuid language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_id uuid; l record;
begin
  if not public.rol_es('administrador','director','ingenieria','gerente_licitaciones') then
    raise exception 'No tienes permiso para crear obras';
  end if;

  select * into l from public.licitaciones_privadas where id = p_licitacion;
  if not found then
    raise exception 'La licitación privada % no existe', p_licitacion;
  end if;
  if l.estado <> 'ganada' then
    raise exception 'La licitación está en estado "%": solo se crea la obra cuando está ganada', l.estado;
  end if;
  if exists (select 1 from public.proyectos where licitacion_privada_id = p_licitacion) then
    raise exception 'Esa licitación ya tiene una obra creada';
  end if;

  insert into public.proyectos (
    codigo, nombre, origen, licitacion_privada_id, cliente, ubicacion,
    monto_contratado, divisa, estado, responsable)
  values (
    coalesce(p_codigo, l.codigo, 'PRIV-' || left(p_licitacion::text, 8)),
    l.titulo, 'privada', p_licitacion, l.cliente, l.ubicacion,
    coalesce(p_monto_contratado, l.monto_ofertado, l.monto_estimado),
    l.divisa, 'planificacion', auth.uid())
  returning id into v_id;

  return v_id;
end $$;

-- Comprueban el rol por dentro, pero nunca deben ser invocables sin sesión.
revoke execute on function public.crear_obra_desde_oportunidad(uuid,text,numeric) from public;
revoke execute on function public.crear_obra_desde_privada(uuid,text,numeric)     from public;
grant  execute on function public.crear_obra_desde_oportunidad(uuid,text,numeric) to authenticated;
grant  execute on function public.crear_obra_desde_privada(uuid,text,numeric)     to authenticated;

-- Endurecimiento heredado de 0001: un disparador no debe exponerse como RPC.
revoke execute on function public.handle_new_user()    from public;
revoke execute on function public.current_user_role()  from public;
grant  execute on function public.current_user_role()  to authenticated;
