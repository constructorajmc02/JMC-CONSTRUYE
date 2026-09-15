-- ============================================================
-- Alertas por rubro del RPE + prellenado de documentos.
-- Requiere 0001, 0002 y 0003.
--
-- Hasta aquí el tablero solo seguía procesos con objeto_proceso = 'Obras'.
-- Eso dejaba fuera mantenimiento de edificaciones y servicios de ingeniería,
-- que están en el RPE de JMC pero la DGCP clasifica como Servicios: 43
-- licitaciones abiertas invisibles. Filtrar por familia UNSPSC es lo que de
-- verdad corresponde al registro de la empresa.
-- ============================================================

-- ------------------------------------------------------------
-- Rubros de JMC (familias UNSPSC del RPE 25564)
-- ------------------------------------------------------------
create table if not exists public.jmc_rubros (
  familia_unspsc text primary key,
  descripcion    text not null,
  activo         boolean not null default true,
  origen         text not null default 'rpe',
  notas          text
);
comment on table public.jmc_rubros is
  'Familias UNSPSC en las que JMC esta registrada en el RPE. Definen que licitaciones le interesan.';

insert into public.jmc_rubros (familia_unspsc, descripcion, notas) values
  ('72130000','Construcción general de edificios','Rubro principal'),
  ('30200000','Estructuras prefabricadas', null),
  ('30220000','Estructuras permanentes', null),
  ('72100000','Mantenimiento y reparaciones de construcciones e instalaciones', null),
  ('81100000','Servicios profesionales de ingeniería', null)
on conflict (familia_unspsc) do nothing;

-- ------------------------------------------------------------
-- Renglones de los procesos, con su código UNSPSC
-- ------------------------------------------------------------
create table if not exists public.dgcp_articulos (
  id                       bigserial primary key,
  codigo_proceso           text not null,
  familia_unspsc           text,
  clase_unspsc             text,
  subclase_unspsc          text,
  descripcion_articulo     text,
  descripcion_usuario      text,
  cuenta_presupuestaria    text,
  cantidad                 numeric,
  unidad_medida            text,
  precio_unitario_estimado numeric,
  precio_total_estimado    numeric,
  fecha_publicacion        timestamptz,
  sincronizado_en          timestamptz not null default now()
);
comment on table public.dgcp_articulos is
  'Renglones de cada proceso con su codigo UNSPSC. Solo se traen los de las familias de jmc_rubros.';

create unique index if not exists dgcp_articulos_unico on public.dgcp_articulos
  (codigo_proceso, coalesce(subclase_unspsc,''), md5(coalesce(descripcion_usuario,'')), coalesce(cantidad,0));
create index if not exists dgcp_articulos_proceso_idx on public.dgcp_articulos (codigo_proceso);
create index if not exists dgcp_articulos_familia_idx on public.dgcp_articulos (familia_unspsc);
create index if not exists dgcp_articulos_fecha_idx   on public.dgcp_articulos (fecha_publicacion desc);

alter table public.oportunidades add column if not exists motivo_ingreso text;

-- ------------------------------------------------------------
create or replace function public.dgcp_traer_articulos(
  desde date default null,
  max_paginas_por_rubro integer default 6,
  por_pagina integer default 500
)
returns table (rubro text, paginas integer, articulos integer, procesos integer)
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r record; v_resp jsonb; v_content jsonb;
  v_pag integer; v_total integer; v_n integer; v_min timestamptz;
  v_desde date; n_art integer; n_pag integer; n_proc integer;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '90');
  v_desde := coalesce(desde, current_date - 60);

  for r in select familia_unspsc, descripcion from public.jmc_rubros where activo loop
    n_art := 0; n_pag := 0; v_pag := 1; v_total := 1;
    loop
      v_resp := (extensions.http_get(
        'https://datosabiertos.dgcp.gob.do/api-dgcp/v1/procesos/articulos?limit='
        || por_pagina || '&page=' || v_pag || '&familia=' || r.familia_unspsc
      )).content::jsonb;

      if coalesce((v_resp->>'hasError')::boolean, false) then
        raise exception 'DGCP articulos %: %', r.familia_unspsc,
          coalesce(v_resp #>> '{payload,message}', 'error');
      end if;

      v_total   := coalesce((v_resp->>'pages')::int, 1);
      v_content := v_resp #> '{payload,content}';
      v_n       := coalesce(jsonb_array_length(v_content), 0);
      exit when v_n = 0;
      n_pag := n_pag + 1;

      insert into public.dgcp_articulos (
        codigo_proceso, familia_unspsc, clase_unspsc, subclase_unspsc,
        descripcion_articulo, descripcion_usuario, cuenta_presupuestaria,
        cantidad, unidad_medida, precio_unitario_estimado, precio_total_estimado,
        fecha_publicacion)
      select
        trim(a->>'codigo_proceso'), a->>'familia_unspsc', a->>'clase_unspsc',
        a->>'subclase_unspsc', a->>'descripcion_articulo', a->>'descripcion_usuario',
        a->>'cuenta_presupuestaria',
        case when jsonb_typeof(a->'cantidad') = 'number' then (a->>'cantidad')::numeric end,
        a->>'unidad_medida',
        case when jsonb_typeof(a->'precio_unitario_estimado') = 'number'
             then (a->>'precio_unitario_estimado')::numeric end,
        case when jsonb_typeof(a->'precio_total_estimado') = 'number'
             then (a->>'precio_total_estimado')::numeric end,
        public.dgcp_ts(a->>'fecha_publicacion')
      from jsonb_array_elements(v_content) a
      where nullif(trim(a->>'codigo_proceso'),'') is not null
      on conflict do nothing;
      get diagnostics v_n = row_count;
      n_art := n_art + v_n;

      select min(public.dgcp_ts(a->>'fecha_publicacion')) into v_min
      from jsonb_array_elements(v_content) a;

      v_pag := v_pag + 1;
      exit when v_pag > v_total
             or n_pag >= max_paginas_por_rubro
             or (v_min is not null and v_min::date < v_desde);
    end loop;

    select count(distinct codigo_proceso) into n_proc
    from public.dgcp_articulos where familia_unspsc = r.familia_unspsc;

    rubro := r.familia_unspsc; paginas := n_pag; articulos := n_art; procesos := n_proc;
    return next;
  end loop;
end $$;

-- ------------------------------------------------------------
-- Una licitación entra al tablero si es Obra O si cae en un rubro del RPE.
-- ------------------------------------------------------------
create or replace function public.sincronizar_oportunidades()
returns table (nuevas integer, actualizadas integer)
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n_new integer; n_upd integer;
begin
  with candidatos as (
    select p.codigo_proceso,
           (p.objeto_proceso = 'Obras') as por_obra,
           exists (
             select 1 from public.dgcp_articulos a
             join public.jmc_rubros r on r.familia_unspsc = a.familia_unspsc and r.activo
             where a.codigo_proceso = p.codigo_proceso
           ) as por_rubro
    from public.dgcp_procesos p
  ), relevantes as (
    select codigo_proceso,
           case when por_obra and por_rubro then 'obra+rubro'
                when por_obra               then 'obra'
                else                             'rubro' end as motivo
    from candidatos where por_obra or por_rubro
  )
  insert into public.oportunidades (codigo_proceso, motivo_ingreso)
  select codigo_proceso, motivo from relevantes
  on conflict (codigo_proceso) do nothing;
  get diagnostics n_new = row_count;

  with candidatos as (
    select o.codigo_proceso,
           (p.objeto_proceso = 'Obras') as por_obra,
           exists (
             select 1 from public.dgcp_articulos a
             join public.jmc_rubros r on r.familia_unspsc = a.familia_unspsc and r.activo
             where a.codigo_proceso = o.codigo_proceso
           ) as por_rubro
    from public.oportunidades o
    join public.dgcp_procesos p on p.codigo_proceso = o.codigo_proceso
  )
  update public.oportunidades o set motivo_ingreso =
    case when c.por_obra and c.por_rubro then 'obra+rubro'
         when c.por_obra                 then 'obra'
         else                                 'rubro' end
  from candidatos c
  where c.codigo_proceso = o.codigo_proceso
    and o.motivo_ingreso is distinct from
        (case when c.por_obra and c.por_rubro then 'obra+rubro'
              when c.por_obra                 then 'obra'
              else                                 'rubro' end);
  get diagnostics n_upd = row_count;

  return query select n_new, n_upd;
end $$;

-- ------------------------------------------------------------
-- Los renglones por rubro entran al ciclo automatico.
-- ------------------------------------------------------------
create or replace function public.dgcp_sincronizar_complementos(
  limite_documentos integer default 120,
  limite_contratos  integer default 120,
  con_pacc          boolean default false,
  con_articulos     boolean default true
)
returns table (documentos integer, contratos integer, pacc integer,
               articulos integer, oportunidades_nuevas integer, fallos integer)
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare d record; c record; o record; n_pacc integer := 0; n_art integer := 0;
begin
  select * into d from public.dgcp_traer_documentos(limite_documentos);
  select * into c from public.dgcp_traer_contratos(limite_contratos);
  if con_pacc then n_pacc := public.dgcp_traer_pacc(); end if;
  if con_articulos then
    select coalesce(sum(a.articulos), 0) into n_art
    from public.dgcp_traer_articulos(current_date - 30, 3, 500) a;
  end if;
  select * into o from public.sincronizar_oportunidades();
  return query select d.documentos, c.contratos, n_pacc, n_art, o.nuevas, d.fallos + c.fallos;
end $$;

drop function if exists public.dgcp_sincronizar_complementos(integer,integer,boolean);

-- ============================================================
-- PRELLENADO
-- ============================================================

-- Historial propio de adjudicaciones: respalda "Experiencia Contratista".
-- Ojo: /contratos SI acepta el filtro `rpe` (a diferencia de /proveedores,
-- que devuelve 500).
create table if not exists public.jmc_historial (
  codigo_contrato    text primary key,
  codigo_proceso     text,
  unidad_compra      text,
  descripcion        text,
  valor_contratado   numeric,
  divisa             text,
  estado_contrato    text,
  fecha_adjudicacion timestamptz,
  plazo_pago_factura text,
  url_contrato       text,
  sincronizado_en    timestamptz not null default now()
);
comment on table public.jmc_historial is
  'Adjudicaciones ganadas por JMC segun la DGCP (RPE 25564).';

create or replace function public.jmc_traer_historial(p_rpe integer default 25564)
returns integer language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_resp jsonb; v_content jsonb; n integer := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '60');
  v_resp := (extensions.http_get(
    'https://datosabiertos.dgcp.gob.do/api-dgcp/v1/contratos?limit=1000&rpe=' || p_rpe
  )).content::jsonb;

  if coalesce((v_resp->>'hasError')::boolean, false) then
    raise exception 'DGCP: %', coalesce(v_resp #>> '{payload,message}', 'error');
  end if;

  v_content := v_resp #> '{payload,content}';
  if v_content is null then return 0; end if;

  insert into public.jmc_historial as h (
    codigo_contrato, codigo_proceso, unidad_compra, descripcion,
    valor_contratado, divisa, estado_contrato, fecha_adjudicacion,
    plazo_pago_factura, url_contrato, sincronizado_en)
  select
    trim(c->>'codigo_contrato'), c->>'codigo_proceso', c->>'unidad_compra',
    c->>'descripcion',
    case when jsonb_typeof(c->'valor_contratado') = 'number'
         then (c->>'valor_contratado')::numeric end,
    c->>'divisa', c->>'estado_contrato',
    public.dgcp_ts(c->>'fecha_adjudicacion'),
    c->>'plazo_pago_factura', c->>'url_contrato', now()
  from jsonb_array_elements(v_content) c
  where nullif(trim(c->>'codigo_contrato'),'') is not null
  on conflict (codigo_contrato) do update set
    estado_contrato = excluded.estado_contrato,
    valor_contratado = excluded.valor_contratado,
    sincronizado_en = now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Catalogo de lo que entrega el oferente. Los tipos salen de los 13.868
-- pliegos reales ya cargados, no de una lista inventada.
create table if not exists public.requisitos_oferta (
  clave       text primary key,
  requisito   text not null,
  tipo_dgcp   text,
  lo_entrega  text not null default 'oferente'
              check (lo_entrega in ('oferente','institucion')),
  fuente      text,
  obligatorio boolean not null default true,
  orden       integer not null default 0,
  notas       text
);

insert into public.requisitos_oferta (clave, requisito, tipo_dgcp, fuente, orden, notas) values
  ('formulario_oferente','Formulario de Información sobre Oferente','Formulario de Información sobre Oferente','companies',10,'Se prellena entero con los datos de la empresa'),
  ('rpe','Constancia del Registro de Proveedores del Estado',null,'documents',20,null),
  ('registro_mercantil','Registro Mercantil vigente',null,'documents',30,null),
  ('estatutos','Estatutos sociales',null,'documents',40,null),
  ('acta_asamblea','Acta de asamblea / nombramiento',null,'documents',50,null),
  ('ir2','Declaración jurada anual ISR (IR-2)',null,'documents',60,null),
  ('dgii_al_dia','Certificación DGII de estar al día',null,'documents',70,'No está en el expediente'),
  ('tss','Certificación TSS',null,'documents',80,'No está en el expediente'),
  ('estados_financieros','Estados financieros auditados',null,'documents',90,'No está en el expediente'),
  ('experiencia','Experiencia del contratista','Experiencia Contratista','jmc_historial',100,'Se arma con las adjudicaciones de la DGCP y los proyectos'),
  ('personal','Personal en plantilla del oferente','Personal Plantilla Oferente','personal',110,'Falta registrar el personal'),
  ('curriculos','Currículo del personal profesional propuesto','Currículo Personal Profesional Propuesto','personal',120,'Falta registrar el personal'),
  ('experiencia_personal','Experiencia profesional del personal principal','Experiencia Profesional Personal Principal','personal',130,'Falta registrar el personal'),
  ('equipos','Equipos del oferente','Equipos Oferente','articulos',140,'Se arma con el inventario tipo equipo'),
  ('oferta_economica','Oferta económica','Oferta Económica (Cotización)','partidas',150,'Se genera del presupuesto por partidas'),
  ('oferta_tecnica','Oferta técnica','Oferta técnica',null,160,null),
  ('garantia','Garantía de seriedad de la oferta',null,null,170,'Se tramita con el banco o la aseguradora')
on conflict (clave) do nothing;

-- ------------------------------------------------------------
-- Vistas
-- ------------------------------------------------------------
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
    when 'partidas'      then (select count(*) from public.partidas)
    else 0
  end as elementos
from public.requisitos_oferta r
where r.lo_entrega = 'oferente';
comment on view public.v_expediente_listo is
  'Estado de preparacion de JMC para ofertar: que requisito esta cubierto y cual no.';

create or replace view public.v_formulario_oferente
with (security_invoker = true) as
select
  c.legal_name          as razon_social,
  c.trade_name          as nombre_comercial,
  c.rnc, c.rpe,
  c.company_type        as forma_juridica,
  c.incorporation_date  as fecha_constitucion,
  c.mercantile_registry as registro_mercantil,
  c.social_object       as objeto_social,
  c.address             as direccion,
  c.phones              as telefonos,
  c.emails              as correos,
  c.website             as sitio_web,
  (select string_agg(ca.code || ' — ' || ca.name, E'\n' order by ca.is_primary desc, ca.code)
     from public.commercial_activities ca where ca.company_id = c.id) as actividades,
  (select string_agg(s.full_name || ' (' || s.role::text ||
                     coalesce(', ' || s.position, '') || ')', E'\n' order by s.role)
     from public.company_stakeholders s where s.company_id = c.id)    as representantes,
  (select string_agg(b.bank_name || ' — ' || coalesce(b.account_type,'') ||
                     ' ' || coalesce(b.currency,''), E'\n')
     from public.bank_accounts b where b.company_id = c.id)           as cuentas_bancarias,
  (select r.rpe_number || ' (' || r.status::text || ')'
     from public.rpe_records r where r.company_id = c.id limit 1)     as estado_rpe
from public.companies c
where c.is_primary;
comment on view public.v_formulario_oferente is
  'Datos de JMC listos para volcar en el Formulario de Informacion sobre Oferente de cualquier pliego.';

-- El tablero, ahora con el motivo de ingreso y los rubros que coinciden.
drop view if exists public.v_oportunidades;
create view public.v_oportunidades
with (security_invoker = true) as
select
  o.id, o.estado as seguimiento, o.responsable, o.monto_ofertado,
  o.motivo_descarte, o.notas, o.motivo_ingreso,
  p.codigo_proceso, p.titulo, p.descripcion, p.modalidad, p.estado_proceso,
  p.objeto_proceso, p.monto_estimado, p.divisa, p.fecha_publicacion,
  p.fecha_fin_recepcion_ofertas, p.fecha_apertura_ofertas,
  p.duracion_contrato, p.area_requiriente, p.dirigido_mipymes, p.url,
  u.codigo_unidad_compra,
  coalesce(u.acronimo, u.unidad_compra) as institucion,
  u.unidad_compra                       as institucion_nombre,
  u.seguida                             as institucion_seguida,
  (p.estado_proceso = 'Proceso publicado'
   and p.fecha_fin_recepcion_ofertas > now())                    as abierta,
  extract(day from p.fecha_fin_recepcion_ofertas - now())::int   as dias_para_cierre,
  (select count(*) from public.dgcp_documentos d
    where d.codigo_proceso = p.codigo_proceso)                   as documentos,
  rub.rubros,
  adj.razon_social     as adjudicado_a,
  adj.valor_contratado as valor_adjudicado
from public.oportunidades o
join public.dgcp_procesos p             on p.codigo_proceso = o.codigo_proceso
left join public.dgcp_unidades_compra u on u.codigo_unidad_compra = p.codigo_unidad_compra
left join lateral (
  select array_agg(distinct r.descripcion order by r.descripcion) as rubros
  from public.dgcp_articulos a
  join public.jmc_rubros r on r.familia_unspsc = a.familia_unspsc and r.activo
  where a.codigo_proceso = p.codigo_proceso
) rub on true
left join lateral (
  select c.razon_social, c.valor_contratado
  from public.dgcp_contratos c
  where c.codigo_proceso = p.codigo_proceso
  order by c.valor_contratado desc nulls last
  limit 1
) adj on true;
comment on view public.v_oportunidades is
  'Licitaciones que le interesan a JMC (por ser Obra o por caer en un rubro de su RPE).';

-- ============================================================
-- Permisos
-- ============================================================
alter table public.dgcp_articulos    enable row level security;
alter table public.jmc_rubros        enable row level security;
alter table public.jmc_historial     enable row level security;
alter table public.requisitos_oferta enable row level security;

drop policy if exists articulos_lectura  on public.dgcp_articulos;
drop policy if exists rubros_lectura     on public.jmc_rubros;
drop policy if exists historial_lectura  on public.jmc_historial;
drop policy if exists requisitos_lectura on public.requisitos_oferta;
create policy articulos_lectura  on public.dgcp_articulos    for select to authenticated using (true);
create policy rubros_lectura     on public.jmc_rubros        for select to authenticated using (true);
create policy historial_lectura  on public.jmc_historial     for select to authenticated using (true);
create policy requisitos_lectura on public.requisitos_oferta for select to authenticated using (true);

drop policy if exists rubros_escritura on public.jmc_rubros;
create policy rubros_escritura on public.jmc_rubros
  for all to authenticated
  using      (public.rol_es('administrador','director','gerente_licitaciones'))
  with check (public.rol_es('administrador','director','gerente_licitaciones'));

drop policy if exists requisitos_escritura on public.requisitos_oferta;
create policy requisitos_escritura on public.requisitos_oferta
  for all to authenticated
  using      (public.rol_es('administrador','director','gerente_licitaciones','legal'))
  with check (public.rol_es('administrador','director','gerente_licitaciones','legal'));

grant select on public.v_oportunidades      to authenticated;
grant select on public.v_expediente_listo   to authenticated;
grant select on public.v_formulario_oferente to authenticated;

-- IMPORTANTE: hacen falta LAS DOS revocaciones. `from public` quita el grant
-- implicito de toda funcion nueva; `from anon, authenticated` quita los grants
-- EXPLICITOS que Supabase otorga por sus default privileges en el esquema
-- public. Con una sola no basta y el advisor lo detecta.
do $$
declare f text;
begin
  foreach f in array array[
    'public.dgcp_traer_articulos(date,integer,integer)',
    'public.sincronizar_oportunidades()',
    'public.jmc_traer_historial(integer)',
    'public.dgcp_sincronizar_complementos(integer,integer,boolean,boolean)'
  ] loop
    execute format('revoke execute on function %s from public', f);
    execute format('revoke execute on function %s from anon, authenticated', f);
  end loop;
end $$;
