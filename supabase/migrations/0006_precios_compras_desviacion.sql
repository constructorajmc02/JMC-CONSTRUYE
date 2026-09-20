-- ============================================================
-- Adaptación de lo que resuelven Emporio y Malla y aquí faltaba.
-- Requiere 0001–0005.
--
-- Emporio lo explica con un caso real: un contratista pidió todo el acero del
-- edificio cuando apenas se había excavado el hoyo. US$40.000 enterrados. No
-- fue un error de cálculo — fue que la orden de compra no estaba conectada al
-- presupuesto ni al avance de la obra. De ahí salen las órdenes de compra
-- validadas contra la partida.
--
-- Malla nombra el otro indicador: "avance 82% · presupuesto 91% usado ⚠".
-- De ahí sale el semáforo, y lo de "subcontratistas que cobran de más".
--
-- Y el banco de precios: los dos ofrecen "precios históricos", pero dependen
-- de que la empresa cargue su propio histórico. Aquí se arranca con los
-- 30.829 precios unitarios que la propia DGCP publica.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Unificar los dos modelos de presupuesto que habían quedado compitiendo.
--    `partidas` (de 0003, colgando de proyectos) tenía 0 filas;
--    `presupuesto_partidas` (de 0005) tenía las 272 reales.
--    v_obra_avance leía el vacío, así que habría mostrado avance cero aunque
--    el presupuesto estuviera cargado.
-- ------------------------------------------------------------
alter table public.cubicacion_partidas
  drop constraint if exists cubicacion_partidas_partida_id_fkey;
alter table public.cubicacion_partidas
  add constraint cubicacion_partidas_partida_id_fkey
  foreign key (partida_id) references public.presupuesto_partidas(id) on delete cascade;
comment on column public.cubicacion_partidas.partida_id is
  'Apunta a presupuesto_partidas. El precio sale de costo_unitario o del APU.';

drop view if exists public.v_obra_avance;
drop table if exists public.partidas cascade;   -- se lleva v_expediente_listo: se recrea abajo

create view public.v_obra_avance
with (security_invoker = true) as
select
  p.id as proyecto_id, p.codigo, p.nombre, p.cliente, p.estado, p.monto_contratado,
  coalesce(pres.presupuestado, 0) as presupuestado,
  coalesce(ejec.ejecutado, 0)     as ejecutado,
  case when coalesce(pres.presupuestado,0) > 0
       then round(100.0 * coalesce(ejec.ejecutado,0) / pres.presupuestado, 1) end as avance_pct,
  coalesce(fact.facturado, 0)         as facturado,
  coalesce(mat.consumo_materiales, 0) as consumo_materiales,
  coalesce(caja.gastos_caja, 0)       as gastos_caja,
  coalesce(sub.subcontratado, 0)      as subcontratado,
  p.monto_contratado - coalesce(mat.consumo_materiales,0)
    - coalesce(caja.gastos_caja,0) - coalesce(sub.subcontratado,0) as margen_estimado
from public.proyectos p
left join lateral (
  select sum(pp.cantidad * coalesce(pp.costo_unitario, public.costo_apu(pp.apu_id), 0)) as presupuestado
  from public.presupuesto_partidas pp
  join public.presupuestos b on b.id = pp.presupuesto_id
  where b.proyecto_id = p.id
) pres on true
left join lateral (
  select sum(cp.cantidad * coalesce(pp.costo_unitario, public.costo_apu(pp.apu_id), 0)) as ejecutado
  from public.cubicacion_partidas cp
  join public.cubicaciones c          on c.id = cp.cubicacion_id
  join public.presupuesto_partidas pp on pp.id = cp.partida_id
  where c.proyecto_id = p.id and c.estado in ('aprobada','facturada')
) ejec on true
left join lateral (
  select sum(total) as facturado from public.facturas
  where proyecto_id = p.id and estado <> 'anulada'
) fact on true
left join lateral (
  select sum(cantidad * coalesce(costo_unitario,0)) as consumo_materiales
  from public.movimientos_inventario where proyecto_id = p.id and tipo = 'salida'
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
grant select on public.v_obra_avance to authenticated;

create or replace view public.v_expediente_listo
with (security_invoker = true) as
select
  r.clave, r.requisito, r.fuente, r.obligatorio, r.orden, r.notas,
  case r.fuente
    when 'companies'     then (select count(*) from public.companies where is_primary)
    when 'documents'     then (select count(*) from public.documents d
                                where d.status = 'vigente'
                                  and (d.name ilike '%' || split_part(r.requisito,' ',1) || '%'
                                       or d.doc_type ilike '%' || split_part(r.requisito,' ',1) || '%'))
    when 'jmc_historial' then (select count(*) from public.jmc_historial)
    when 'personal'      then 0
    when 'articulos'     then (select count(*) from public.articulos where tipo = 'equipo' and activo)
    when 'partidas'      then (select count(*) from public.presupuesto_partidas)
    else 0
  end as elementos
from public.requisitos_oferta r
where r.lo_entrega = 'oferente';
grant select on public.v_expediente_listo to authenticated;

-- ------------------------------------------------------------
-- 1. Banco de precios de referencia desde la DGCP
-- ------------------------------------------------------------
create index if not exists dgcp_articulos_texto_idx on public.dgcp_articulos
  using gin (to_tsvector('spanish',
    coalesce(descripcion_usuario,'') || ' ' || coalesce(descripcion_articulo,'')));

-- Mediana y cuartiles, no promedio: un renglón atípico distorsiona el
-- promedio, y aquí los hay (un mismo artículo va de RD$43 a RD$12.289).
create or replace view public.v_precios_mercado
with (security_invoker = true) as
select
  a.subclase_unspsc,
  max(a.descripcion_articulo) as articulo,
  a.unidad_medida,
  count(*) as observaciones,
  round(percentile_cont(0.5)  within group (order by a.precio_unitario_estimado)::numeric, 2) as precio_mediano,
  round(percentile_cont(0.25) within group (order by a.precio_unitario_estimado)::numeric, 2) as precio_p25,
  round(percentile_cont(0.75) within group (order by a.precio_unitario_estimado)::numeric, 2) as precio_p75,
  min(a.precio_unitario_estimado) as precio_minimo,
  max(a.precio_unitario_estimado) as precio_maximo,
  max(a.fecha_publicacion)::date  as ultima_observacion
from public.dgcp_articulos a
where a.precio_unitario_estimado > 0 and a.subclase_unspsc is not null
group by a.subclase_unspsc, a.unidad_medida;
comment on view public.v_precios_mercado is
  'Precio de mercado por subclase UNSPSC segun lo publicado por la DGCP.';
grant select on public.v_precios_mercado to authenticated;

-- Propone precios; NO autocompleta. La decisión es de una persona.
create or replace function public.sugerir_precio(
  p_descripcion text, p_unidad text default null, p_limite integer default 5
)
returns table (
  subclase_unspsc text, descripcion_referencia text, unidad_medida text,
  observaciones bigint, precio_mediano numeric, precio_p25 numeric,
  precio_p75 numeric, ultima_observacion date, similitud real
)
language sql stable
set search_path = public, pg_temp
as $$
  with consulta as (
    select plainto_tsquery('spanish', p_descripcion) as q, lower(coalesce(p_unidad,'')) as u
  ),
  coincidencias as (
    select
      a.subclase_unspsc, a.unidad_medida, a.precio_unitario_estimado, a.fecha_publicacion,
      coalesce(a.descripcion_usuario, a.descripcion_articulo) as texto,
      ts_rank(to_tsvector('spanish',
        coalesce(a.descripcion_usuario,'') || ' ' || coalesce(a.descripcion_articulo,'')), c.q) as rank
    from public.dgcp_articulos a, consulta c
    where a.precio_unitario_estimado > 0
      and a.subclase_unspsc is not null
      and to_tsvector('spanish',
            coalesce(a.descripcion_usuario,'') || ' ' || coalesce(a.descripcion_articulo,'')) @@ c.q
      and (c.u = '' or lower(a.unidad_medida) = c.u)
  )
  select
    m.subclase_unspsc,
    (array_agg(m.texto order by m.rank desc))[1],
    m.unidad_medida,
    count(*),
    round(percentile_cont(0.5)  within group (order by m.precio_unitario_estimado)::numeric, 2),
    round(percentile_cont(0.25) within group (order by m.precio_unitario_estimado)::numeric, 2),
    round(percentile_cont(0.75) within group (order by m.precio_unitario_estimado)::numeric, 2),
    max(m.fecha_publicacion)::date,
    max(m.rank)
  from coincidencias m
  group by m.subclase_unspsc, m.unidad_medida
  order by max(m.rank) desc, count(*) desc
  limit p_limite;
$$;
revoke execute on function public.sugerir_precio(text,text,integer) from public;
revoke execute on function public.sugerir_precio(text,text,integer) from anon;
grant  execute on function public.sugerir_precio(text,text,integer) to authenticated;

-- Detecta el renglón cotizado demasiado caro o demasiado barato antes de enviar.
create or replace view public.v_presupuesto_vs_mercado
with (security_invoker = true) as
select
  pp.id as partida_id, pp.presupuesto_id, pp.descripcion, pp.unidad,
  pp.cantidad, pp.costo_unitario,
  s.precio_mediano as precio_mercado, s.observaciones,
  case when pp.costo_unitario is null then 'sin_precio'
       when s.precio_mediano is null  then 'sin_referencia'
       when pp.costo_unitario > s.precio_p75 * 1.2 then 'muy_por_encima'
       when pp.costo_unitario < s.precio_p25 * 0.8 then 'muy_por_debajo'
       else 'en_rango' end as senal
from public.presupuesto_partidas pp
left join lateral (select * from public.sugerir_precio(pp.descripcion, pp.unidad, 1)) s on true;
grant select on public.v_presupuesto_vs_mercado to authenticated;

-- ------------------------------------------------------------
-- 2. Órdenes de compra atadas al presupuesto
-- ------------------------------------------------------------
do $$ begin
  create type public.estado_orden_compra as enum
    ('borrador','aprobada','enviada','recibida_parcial','recibida','anulada');
exception when duplicate_object then null; end $$;

create table if not exists public.ordenes_compra (
  id uuid primary key default gen_random_uuid(),
  numero text unique not null,
  proyecto_id uuid references public.proyectos(id) on delete set null,
  proveedor text not null,
  rnc_proveedor text,
  estado public.estado_orden_compra not null default 'borrador',
  fecha date not null default current_date,
  fecha_entrega date,
  moneda text not null default 'DOP',
  notas text,
  solicitada_por uuid references auth.users(id) on delete set null,
  aprobada_por uuid references auth.users(id) on delete set null,
  aprobada_en timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ordenes_compra_proyecto_idx on public.ordenes_compra (proyecto_id);
create index if not exists ordenes_compra_estado_idx   on public.ordenes_compra (estado);
drop trigger if exists set_updated_at on public.ordenes_compra;
create trigger set_updated_at before update on public.ordenes_compra
  for each row execute function public.set_updated_at();

create table if not exists public.orden_compra_lineas (
  id uuid primary key default gen_random_uuid(),
  orden_id uuid not null references public.ordenes_compra(id) on delete cascade,
  partida_id uuid references public.presupuesto_partidas(id) on delete set null,
  articulo_id uuid references public.articulos(id) on delete set null,
  descripcion text not null,
  unidad text not null,
  cantidad numeric not null check (cantidad > 0),
  precio_unitario numeric not null default 0,
  monto numeric generated always as (cantidad * precio_unitario) stored,
  cantidad_recibida numeric not null default 0,
  orden integer not null default 0
);
create index if not exists orden_lineas_orden_idx   on public.orden_compra_lineas (orden_id);
create index if not exists orden_lineas_partida_idx on public.orden_compra_lineas (partida_id);

create table if not exists public.subcontrato_pagos (
  id bigserial primary key,
  subcontrato_id uuid not null references public.subcontratos(id) on delete cascade,
  monto numeric not null check (monto > 0),
  concepto text,
  comprobante text,
  fecha date not null default current_date,
  registrado_por uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists subcontrato_pagos_idx on public.subcontrato_pagos (subcontrato_id, fecha desc);

create or replace view public.v_partida_consumo
with (security_invoker = true) as
select
  pp.id as partida_id, pp.presupuesto_id, b.proyecto_id,
  pp.descripcion, pp.unidad,
  pp.cantidad as cantidad_presupuestada,
  pp.cantidad * coalesce(pp.costo_unitario, public.costo_apu(pp.apu_id), 0) as monto_presupuestado,
  coalesce(oc.cantidad_comprada, 0) as cantidad_comprada,
  coalesce(oc.monto_comprado, 0)    as monto_comprado,
  pp.cantidad * coalesce(pp.costo_unitario, public.costo_apu(pp.apu_id), 0)
    - coalesce(oc.monto_comprado, 0) as monto_disponible,
  case
    when pp.cantidad * coalesce(pp.costo_unitario, public.costo_apu(pp.apu_id), 0) = 0 then 'sin_presupuesto'
    when coalesce(oc.monto_comprado,0) >
         pp.cantidad * coalesce(pp.costo_unitario, public.costo_apu(pp.apu_id), 0) then 'excedida'
    when coalesce(oc.monto_comprado,0) >
         pp.cantidad * coalesce(pp.costo_unitario, public.costo_apu(pp.apu_id), 0) * 0.9 then 'al_limite'
    else 'holgada'
  end as senal
from public.presupuesto_partidas pp
join public.presupuestos b on b.id = pp.presupuesto_id
left join lateral (
  select sum(l.cantidad) as cantidad_comprada, sum(l.monto) as monto_comprado
  from public.orden_compra_lineas l
  join public.ordenes_compra o on o.id = l.orden_id
  where l.partida_id = pp.id and o.estado <> 'anulada'
) oc on true;
grant select on public.v_partida_consumo to authenticated;

-- Sin filas = la orden cabe en el presupuesto.
create or replace function public.validar_orden_compra(p_orden uuid)
returns table (
  partida_id uuid, descripcion text, monto_presupuestado numeric,
  monto_ya_comprado numeric, monto_esta_orden numeric, exceso numeric
)
language sql stable
set search_path = public, pg_temp
as $$
  select
    c.partida_id, c.descripcion, c.monto_presupuestado,
    c.monto_comprado - coalesce(e.monto_orden, 0),
    coalesce(e.monto_orden, 0),
    c.monto_comprado - c.monto_presupuestado
  from public.v_partida_consumo c
  join lateral (
    select sum(l.monto) as monto_orden
    from public.orden_compra_lineas l
    where l.partida_id = c.partida_id and l.orden_id = p_orden
  ) e on e.monto_orden is not null
  where c.monto_presupuestado > 0 and c.monto_comprado > c.monto_presupuestado;
$$;
revoke execute on function public.validar_orden_compra(uuid) from public;
revoke execute on function public.validar_orden_compra(uuid) from anon;
grant  execute on function public.validar_orden_compra(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. Semáforo de desviación y estado de subcontratos
-- ------------------------------------------------------------
create or replace view public.v_obra_semaforo
with (security_invoker = true) as
select
  a.proyecto_id, a.codigo, a.nombre, a.cliente, a.estado,
  a.presupuestado, a.ejecutado, a.avance_pct,
  coalesce(g.gastado, 0) as gastado,
  case when a.presupuestado > 0
       then round(100.0 * coalesce(g.gastado,0) / a.presupuestado, 1) end as presupuesto_usado_pct,
  case
    when a.presupuestado = 0 or a.avance_pct is null then 'sin_datos'
    when coalesce(g.gastado,0) / nullif(a.presupuestado,0) * 100 > a.avance_pct + 10 then 'rojo'
    when coalesce(g.gastado,0) / nullif(a.presupuestado,0) * 100 > a.avance_pct + 3  then 'amarillo'
    else 'verde'
  end as semaforo,
  a.margen_estimado
from public.v_obra_avance a
left join lateral (
  select
    coalesce((select sum(cantidad * coalesce(costo_unitario,0))
              from public.movimientos_inventario
              where proyecto_id = a.proyecto_id and tipo = 'salida'), 0)
  + coalesce((select sum(m.monto) from public.movimientos_caja m
              join public.cajas_chicas cc on cc.id = m.caja_id
              where cc.proyecto_id = a.proyecto_id and m.tipo = 'gasto'), 0)
  + coalesce((select sum(l.monto) from public.orden_compra_lineas l
              join public.ordenes_compra o on o.id = l.orden_id
              where o.proyecto_id = a.proyecto_id and o.estado <> 'anulada'), 0)
  + coalesce((select sum(pg.monto) from public.subcontrato_pagos pg
              join public.subcontratos s on s.id = pg.subcontrato_id
              where s.proyecto_id = a.proyecto_id), 0) as gastado
) g on true;
comment on view public.v_obra_semaforo is
  'Rojo cuando el presupuesto se consume mas rapido que el avance de la obra.';
grant select on public.v_obra_semaforo to authenticated;

create or replace view public.v_subcontratos_estado
with (security_invoker = true) as
select
  s.id as subcontrato_id, s.proyecto_id, s.subcontratista, s.rnc,
  s.alcance, s.estado, s.monto as monto_pactado,
  coalesce(p.pagado, 0) as pagado,
  s.monto - coalesce(p.pagado, 0) as pendiente,
  case when s.monto > 0 then round(100.0 * coalesce(p.pagado,0) / s.monto, 1) end as pagado_pct,
  (coalesce(p.pagado,0) > s.monto) as sobrepagado,
  p.ultimo_pago
from public.subcontratos s
left join lateral (
  select sum(monto) as pagado, max(fecha) as ultimo_pago
  from public.subcontrato_pagos where subcontrato_id = s.id
) p on true;
grant select on public.v_subcontratos_estado to authenticated;

-- ------------------------------------------------------------
-- Permisos
-- ------------------------------------------------------------
alter table public.ordenes_compra      enable row level security;
alter table public.orden_compra_lineas enable row level security;
alter table public.subcontrato_pagos   enable row level security;

do $$
declare t text; roles text[];
  w jsonb := jsonb_build_object(
    'ordenes_compra',      array['administrador','director','compras','ingenieria'],
    'orden_compra_lineas', array['administrador','director','compras','ingenieria'],
    'subcontrato_pagos',   array['administrador','director','finanzas']
  );
begin
  for t in select jsonb_object_keys(w) loop
    roles := array(select jsonb_array_elements_text(w -> t));
    execute format('drop policy if exists %I on public.%I', t || '_lectura', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', t || '_lectura', t);
    execute format('drop policy if exists %I on public.%I', t || '_escritura', t);
    execute format(
      'create policy %I on public.%I for all to authenticated
         using (public.rol_es(variadic %L::public.user_role[]))
         with check (public.rol_es(variadic %L::public.user_role[]))',
      t || '_escritura', t, roles, roles);
  end loop;
end $$;

-- ------------------------------------------------------------
-- Correcciones de seguridad detectadas por el advisor
--
-- OJO: `create or replace view` NO conserva `with (security_invoker = true)`.
-- Al recrear v_oportunidades el 17-sep se perdió y la vista pasó a ejecutarse
-- con los privilegios de quien la creó — saltándose el RLS.
-- ------------------------------------------------------------
alter view public.v_oportunidades       set (security_invoker = true);
alter view public.v_presupuesto_totales set (security_invoker = true);
alter function public.checklist_por_licitacion(text) set search_path = public, pg_temp;
