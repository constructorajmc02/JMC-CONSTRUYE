-- ============================================================
-- Integración con la DGCP (Dirección General de Contrataciones Públicas)
--
-- Fuente: https://datosabiertos.dgcp.gob.do/api-dgcp/v1 — API pública, sin
-- autenticación. La ingesta corre DENTRO de Postgres (extensión `http` +
-- `pg_cron`), no en un servidor aparte: así no hace falta administrar llaves.
--
-- Estado final consolidado. Requiere 0001 (define profiles, current_user_role
-- y set_updated_at).
-- ============================================================

create extension if not exists http    with schema extensions;
create extension if not exists pg_cron;

-- ------------------------------------------------------------
-- Ayudantes de conversión: la API devuelve todo como texto.
-- ------------------------------------------------------------
create or replace function public.dgcp_ts(t text)
returns timestamptz language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when t ~ '^\d{4}-\d{2}-\d{2}' then t::timestamptz end
$$;

create or replace function public.dgcp_sino(t text)
returns boolean language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when lower(coalesce(t,'')) in ('si','sí','s') then true
              when lower(coalesce(t,'')) in ('no','n')      then false end
$$;

create or replace function public.dgcp_int(t text)
returns integer language sql immutable set search_path = pg_catalog, pg_temp as $$
  select nullif(regexp_replace(coalesce(t,''), '[^0-9-]', '', 'g'), '')::integer
$$;

-- ------------------------------------------------------------
-- Instituciones compradoras
-- ------------------------------------------------------------
create table if not exists public.dgcp_unidades_compra (
  codigo_unidad_compra  integer primary key,
  unidad_compra         text not null,
  acronimo              text,
  tipo                  text,
  estado                text,
  direccion             text,
  telefono              text,
  correo                text,
  correo_notificaciones text,
  codigo_capitulo       text,
  fecha_registro        timestamptz,
  seguida               boolean not null default false,
  raw                   jsonb not null,
  sincronizado_en       timestamptz not null default now()
);
comment on table  public.dgcp_unidades_compra is 'Instituciones compradoras del Estado (DGCP /unidades_compra).';
comment on column public.dgcp_unidades_compra.seguida is 'true = institución prioritaria para JMC (ETED, ISFODOSU, INABIMA, ayuntamientos...).';

-- ------------------------------------------------------------
-- Procesos de compra
-- ------------------------------------------------------------
create table if not exists public.dgcp_procesos (
  codigo_proceso                 text primary key,
  codigo_unidad_compra           integer references public.dgcp_unidades_compra(codigo_unidad_compra),
  unidad_compra                  text,
  titulo                         text,
  descripcion                    text,
  modalidad                      text,
  tipo_excepcion                 text,
  estado_proceso                 text,
  objeto_proceso                 text,   -- Obras | Bienes | Servicios
  subobjeto_proceso              text,
  divisa                         text,
  monto_estimado                 numeric,
  fecha_publicacion              timestamptz,
  fecha_enmienda                 timestamptz,
  fecha_fin_recepcion_ofertas    timestamptz,
  fecha_apertura_ofertas         timestamptz,
  fecha_estimada_adjudicacion    timestamptz,
  dirigido_mipymes               boolean,
  dirigido_mipymes_mujeres       boolean,
  proceso_lotificado             boolean,
  area_requiriente               text,
  duracion_contrato              text,
  numero_proveedores_notificados integer,
  url                            text,
  raw                            jsonb,
  documentos_traidos_en          timestamptz,
  contratos_traidos_en           timestamptz,
  sincronizado_en                timestamptz not null default now()
);
comment on table  public.dgcp_procesos is 'Procesos de compra publicados por la DGCP. Espejo local.';
comment on column public.dgcp_procesos.objeto_proceso is 'Obras | Bienes | Servicios. JMC solo compite en Obras.';
comment on column public.dgcp_procesos.estado_proceso is '"Proceso publicado" = abierto para ofertar.';
comment on column public.dgcp_procesos.raw is 'JSON original. Solo se guarda para objeto_proceso = Obras (guardarlo todo costaba ~63 MB de los 500 del plan).';

create index if not exists dgcp_procesos_publicacion_idx on public.dgcp_procesos (fecha_publicacion desc);
create index if not exists dgcp_procesos_objeto_idx      on public.dgcp_procesos (objeto_proceso);
create index if not exists dgcp_procesos_estado_idx      on public.dgcp_procesos (estado_proceso);
create index if not exists dgcp_procesos_unidad_idx      on public.dgcp_procesos (codigo_unidad_compra);
create index if not exists dgcp_procesos_cierre_idx      on public.dgcp_procesos (fecha_fin_recepcion_ofertas)
  where estado_proceso = 'Proceso publicado';
create index if not exists dgcp_procesos_texto_idx on public.dgcp_procesos
  using gin (to_tsvector('spanish', coalesce(titulo,'') || ' ' || coalesce(descripcion,'')));

-- ------------------------------------------------------------
-- Pliegos, contratos adjudicados y planes anuales de compra
-- ------------------------------------------------------------
create table if not exists public.dgcp_documentos (
  id                  bigserial primary key,
  codigo_proceso      text not null references public.dgcp_procesos(codigo_proceso) on delete cascade,
  nombre_documento    text not null,
  tipo_documento      text,
  url_documento       text not null,
  fecha_carga_archivo timestamptz,
  sincronizado_en     timestamptz not null default now(),
  unique (codigo_proceso, url_documento)
);
create index if not exists dgcp_documentos_proceso_idx on public.dgcp_documentos (codigo_proceso);
comment on table public.dgcp_documentos is 'Pliegos y anexos publicados por la DGCP para cada proceso.';

create table if not exists public.dgcp_contratos (
  codigo_contrato         text primary key,
  codigo_proceso          text,
  codigo_unidad_compra    integer,
  unidad_compra           text,
  rpe                     integer,   -- proveedor ganador
  razon_social            text,
  estado_contrato         text,
  estado_adjudicacion     text,
  descripcion             text,
  divisa                  text,
  valor_contratado        numeric,
  metodo_pago             text,
  plazo_pago_factura      text,
  fecha_adjudicacion      timestamptz,
  fecha_creacion_contrato timestamptz,
  url_contrato            text,
  sincronizado_en         timestamptz not null default now()
);
create index if not exists dgcp_contratos_proceso_idx on public.dgcp_contratos (codigo_proceso);
create index if not exists dgcp_contratos_rpe_idx     on public.dgcp_contratos (rpe);
create index if not exists dgcp_contratos_fecha_idx   on public.dgcp_contratos (fecha_adjudicacion desc);
comment on table public.dgcp_contratos is 'Adjudicaciones: quién ganó cada proceso y por cuánto. Base del análisis de competencia.';

create table if not exists public.dgcp_pacc (
  uid_pacc             text primary key,
  codigo_unidad_compra integer,
  unidad_compra        text,
  periodo              integer,
  version              text,
  responsable          text,
  correo_responsable   text,
  fecha_publicacion    timestamptz,
  url                  text,
  sincronizado_en      timestamptz not null default now()
);
create index if not exists dgcp_pacc_unidad_idx on public.dgcp_pacc (codigo_unidad_compra, periodo);
comment on table public.dgcp_pacc is 'Plan Anual de Compras y Contrataciones: lo que cada institución piensa licitar.';

-- ------------------------------------------------------------
-- Bitácora
-- ------------------------------------------------------------
create table if not exists public.dgcp_sync (
  id               bigserial primary key,
  recurso          text not null,
  iniciado_en      timestamptz not null default now(),
  terminado_en     timestamptz,
  estado           text not null default 'corriendo',   -- corriendo | ok | error
  paginas_leidas   integer not null default 0,
  registros_leidos integer not null default 0,
  registros_nuevos integer not null default 0,
  desde_fecha      date,
  mensaje          text
);
create index if not exists dgcp_sync_recurso_idx on public.dgcp_sync (recurso, iniciado_en desc);

-- ------------------------------------------------------------
-- Seguimiento propio de JMC sobre una obra de la DGCP
-- ------------------------------------------------------------
do $$ begin
  create type public.oportunidad_estado as enum
    ('nueva','interesa','descartada','preparando','ofertada','ganada','perdida');
exception when duplicate_object then null; end $$;

create table if not exists public.oportunidades (
  id              uuid primary key default gen_random_uuid(),
  codigo_proceso  text not null unique references public.dgcp_procesos(codigo_proceso) on delete cascade,
  estado          public.oportunidad_estado not null default 'nueva',
  responsable     uuid references auth.users(id) on delete set null,
  monto_ofertado  numeric,
  motivo_descarte text,
  notas           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table public.oportunidades is 'Seguimiento de JMC sobre una obra: si interesa, quién la prepara y cómo terminó.';
create index if not exists oportunidades_estado_idx      on public.oportunidades (estado);
create index if not exists oportunidades_responsable_idx on public.oportunidades (responsable);

drop trigger if exists set_updated_at on public.oportunidades;
create trigger set_updated_at before update on public.oportunidades
  for each row execute function public.set_updated_at();

-- ============================================================
-- Cargadores: mapean el JSON de la DGCP a las tablas.
-- ============================================================
create or replace function public.dgcp_cargar_unidades(payload jsonb)
returns integer language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n integer;
begin
  insert into public.dgcp_unidades_compra as d (
    codigo_unidad_compra, unidad_compra, acronimo, tipo, estado, direccion,
    telefono, correo, correo_notificaciones, codigo_capitulo, fecha_registro,
    raw, sincronizado_en)
  select
    public.dgcp_int(u->>'codigo_unidad_compra'),
    coalesce(nullif(trim(u->>'unidad_compra'),''), '(sin nombre)'),
    u->>'acronimo', u->>'tipo', u->>'estado', u->>'direccion',
    u->>'telefono', u->>'correo', u->>'correo_notificaciones',
    u->>'codigo_capitulo', public.dgcp_ts(u->>'fecha_registro'),
    u, now()
  from jsonb_array_elements(payload) u
  where public.dgcp_int(u->>'codigo_unidad_compra') is not null
  on conflict (codigo_unidad_compra) do update set
    unidad_compra = excluded.unidad_compra,
    acronimo = excluded.acronimo, tipo = excluded.tipo, estado = excluded.estado,
    direccion = excluded.direccion, telefono = excluded.telefono,
    correo = excluded.correo, correo_notificaciones = excluded.correo_notificaciones,
    codigo_capitulo = excluded.codigo_capitulo, fecha_registro = excluded.fecha_registro,
    raw = excluded.raw, sincronizado_en = now();
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.dgcp_cargar_procesos(payload jsonb)
returns table (procesos integer, obras_nuevas integer)
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare n_proc integer; n_obras integer;
begin
  -- Red de seguridad para la llave foránea: una institución que aún no está en
  -- el catálogo se da de alta con el nombre que trae el propio proceso.
  insert into public.dgcp_unidades_compra (codigo_unidad_compra, unidad_compra, raw)
  select distinct on (public.dgcp_int(p->>'codigo_unidad_compra'))
         public.dgcp_int(p->>'codigo_unidad_compra'),
         coalesce(nullif(trim(p->>'unidad_compra'),''), '(sin nombre)'),
         jsonb_build_object('origen','proceso','codigo_unidad_compra', p->>'codigo_unidad_compra')
  from jsonb_array_elements(payload) p
  where public.dgcp_int(p->>'codigo_unidad_compra') is not null
  on conflict (codigo_unidad_compra) do nothing;

  with entrantes as (
    select
      trim(p->>'codigo_proceso')                       as codigo_proceso,
      public.dgcp_int(p->>'codigo_unidad_compra')      as codigo_unidad_compra,
      p->>'unidad_compra'                              as unidad_compra,
      p->>'titulo'                                     as titulo,
      p->>'descripcion'                                as descripcion,
      p->>'modalidad'                                  as modalidad,
      p->>'tipo_excepcion'                             as tipo_excepcion,
      p->>'estado_proceso'                             as estado_proceso,
      p->>'objeto_proceso'                             as objeto_proceso,
      p->>'subobjeto_proceso'                          as subobjeto_proceso,
      p->>'divisa'                                     as divisa,
      case when jsonb_typeof(p->'monto_estimado') = 'number'
           then (p->>'monto_estimado')::numeric end    as monto_estimado,
      public.dgcp_ts(p->>'fecha_publicacion')           as fecha_publicacion,
      public.dgcp_ts(p->>'fecha_enmienda')              as fecha_enmienda,
      public.dgcp_ts(p->>'fecha_fin_recepcion_ofertas') as fecha_fin_recepcion_ofertas,
      public.dgcp_ts(p->>'fecha_apertura_ofertas')      as fecha_apertura_ofertas,
      public.dgcp_ts(p->>'fecha_estimada_adjudicacion') as fecha_estimada_adjudicacion,
      public.dgcp_sino(p->>'dirigido_mipymes')          as dirigido_mipymes,
      public.dgcp_sino(p->>'dirigido_mipymes_mujeres')  as dirigido_mipymes_mujeres,
      public.dgcp_sino(p->>'proceso_lotificado')        as proceso_lotificado,
      p->>'area_requiriente'                           as area_requiriente,
      p->>'duracion_contrato'                          as duracion_contrato,
      public.dgcp_int(p->>'numero_proveedores_notificados') as numero_proveedores_notificados,
      p->>'url'                                        as url,
      case when p->>'objeto_proceso' = 'Obras' then p end as raw
    from jsonb_array_elements(payload) p
    where nullif(trim(p->>'codigo_proceso'),'') is not null
  )
  insert into public.dgcp_procesos as d (
    codigo_proceso, codigo_unidad_compra, unidad_compra, titulo, descripcion,
    modalidad, tipo_excepcion, estado_proceso, objeto_proceso, subobjeto_proceso,
    divisa, monto_estimado, fecha_publicacion, fecha_enmienda,
    fecha_fin_recepcion_ofertas, fecha_apertura_ofertas, fecha_estimada_adjudicacion,
    dirigido_mipymes, dirigido_mipymes_mujeres, proceso_lotificado,
    area_requiriente, duracion_contrato, numero_proveedores_notificados, url,
    raw, sincronizado_en)
  select e.*, now() from entrantes e
  on conflict (codigo_proceso) do update set
    estado_proceso = excluded.estado_proceso,
    titulo = excluded.titulo, descripcion = excluded.descripcion,
    monto_estimado = excluded.monto_estimado,
    fecha_enmienda = excluded.fecha_enmienda,
    fecha_fin_recepcion_ofertas = excluded.fecha_fin_recepcion_ofertas,
    fecha_apertura_ofertas = excluded.fecha_apertura_ofertas,
    fecha_estimada_adjudicacion = excluded.fecha_estimada_adjudicacion,
    url = excluded.url, raw = excluded.raw, sincronizado_en = now();
  get diagnostics n_proc = row_count;

  -- Toda obra del lote entra al tablero como "nueva".
  insert into public.oportunidades (codigo_proceso)
  select trim(p->>'codigo_proceso')
  from jsonb_array_elements(payload) p
  where p->>'objeto_proceso' = 'Obras'
    and nullif(trim(p->>'codigo_proceso'),'') is not null
  on conflict (codigo_proceso) do nothing;
  get diagnostics n_obras = row_count;

  return query select n_proc, n_obras;
end $$;

-- ============================================================
-- Sincronización: la base llama a la API ella misma.
-- ============================================================
create or replace function public.dgcp_sincronizar(
  desde date default null,
  max_paginas integer default 20,
  por_pagina integer default 500,
  incluir_unidades boolean default true,
  pagina_inicial integer default 1
)
returns table (corrida bigint, desde_fecha date, paginas integer, leidos integer,
               obras_nuevas integer, ultima_pagina integer, completo boolean)
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id bigint; v_desde date; v_pagina integer;
  v_paginas integer := 0; v_total_pag integer := 1;
  v_leidos integer := 0; v_obras integer := 0; v_obras_pag integer;
  v_resp jsonb; v_content jsonb; v_n integer;
  v_base constant text := 'https://datosabiertos.dgcp.gob.do/api-dgcp/v1';
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '90');

  -- Sin argumentos: incremental desde 3 días antes de lo último guardado
  -- (el solape recoge enmiendas y cambios de estado).
  v_desde := coalesce(
    desde,
    (select (max(fecha_publicacion) - interval '3 days')::date from public.dgcp_procesos),
    (current_date - 30)
  );

  insert into public.dgcp_sync (recurso, desde_fecha)
  values ('procesos', v_desde) returning id into v_id;

  if incluir_unidades then
    v_resp := (extensions.http_get(v_base || '/unidades_compra?limit=1000&page=1')).content::jsonb;
    v_content := v_resp #> '{payload,content}';
    if v_content is not null then perform public.dgcp_cargar_unidades(v_content); end if;
    for v_pagina in 2 .. least(coalesce((v_resp->>'pages')::int, 1), 10) loop
      v_resp := (extensions.http_get(v_base || '/unidades_compra?limit=1000&page=' || v_pagina)).content::jsonb;
      v_content := v_resp #> '{payload,content}';
      if v_content is not null then perform public.dgcp_cargar_unidades(v_content); end if;
    end loop;
  end if;

  v_pagina := greatest(pagina_inicial, 1);
  loop
    v_resp := (extensions.http_get(
      v_base || '/procesos?limit=' || por_pagina
             || '&page=' || v_pagina
             || '&startdate=' || to_char(v_desde, 'YYYY-MM-DD')
    )).content::jsonb;

    if coalesce((v_resp->>'hasError')::boolean, false) then
      raise exception 'DGCP: %', coalesce(v_resp #>> '{payload,message}', 'error desconocido');
    end if;

    v_total_pag := coalesce((v_resp->>'pages')::int, 1);
    v_content   := v_resp #> '{payload,content}';
    v_n         := coalesce(jsonb_array_length(v_content), 0);
    exit when v_n = 0;

    v_paginas := v_paginas + 1;
    v_leidos  := v_leidos + v_n;

    select p.obras_nuevas into v_obras_pag from public.dgcp_cargar_procesos(v_content) p;
    v_obras := v_obras + coalesce(v_obras_pag, 0);

    v_pagina := v_pagina + 1;
    exit when v_pagina > v_total_pag or v_paginas >= max_paginas;
  end loop;

  update public.dgcp_sync set
    estado = 'ok', terminado_en = now(),
    paginas_leidas = v_paginas, registros_leidos = v_leidos, registros_nuevos = v_obras,
    mensaje = case when v_pagina <= v_total_pag then
      format('Faltan páginas: dgcp_sincronizar(desde => %L, pagina_inicial => %s)', v_desde, v_pagina) end
  where id = v_id;

  return query select v_id, v_desde, v_paginas, v_leidos, v_obras, v_pagina - 1, (v_pagina > v_total_pag);

exception when others then
  update public.dgcp_sync set
    estado = 'error', terminado_en = now(),
    paginas_leidas = v_paginas, registros_leidos = v_leidos, mensaje = sqlerrm
  where id = v_id;
  raise;
end $$;

comment on function public.dgcp_sincronizar(date,integer,integer,boolean,integer) is
  'Trae procesos de la DGCP. Sin argumentos: incremental. Para histórico usar desde/pagina_inicial.';

-- ------------------------------------------------------------
-- Pliegos y contratos: una llamada HTTP por proceso, así que van por tandas.
-- Un fallo NO marca el proceso como traído: la siguiente tanda lo reintenta
-- (antes sí lo marcaba y se perdieron los pliegos de 10 de 824 obras).
-- ------------------------------------------------------------
create or replace function public.dgcp_traer_documentos(limite integer default 150)
returns table (procesos_revisados integer, documentos integer, fallos integer)
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r record; v_resp jsonb; v_content jsonb;
  n_proc integer := 0; n_doc integer := 0; n_err integer := 0; n integer;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '45');
  for r in
    select codigo_proceso from public.dgcp_procesos
    where objeto_proceso = 'Obras' and documentos_traidos_en is null
    order by fecha_publicacion desc limit limite
  loop
    begin
      v_resp := (extensions.http_get(
        'https://datosabiertos.dgcp.gob.do/api-dgcp/v1/procesos/documentos?proceso='
        || extensions.urlencode(r.codigo_proceso))).content::jsonb;

      if coalesce((v_resp->>'hasError')::boolean, false) then
        raise exception 'DGCP: %', coalesce(v_resp #>> '{payload,message}', 'error');
      end if;

      v_content := v_resp #> '{payload,content}';
      if v_content is not null and jsonb_typeof(v_content) = 'array' then
        insert into public.dgcp_documentos
          (codigo_proceso, nombre_documento, tipo_documento, url_documento, fecha_carga_archivo)
        select r.codigo_proceso, d->>'nombre_documento', d->>'tipo_documento',
               d->>'url_documento', public.dgcp_ts(d->>'fecha_carga_archivo')
        from jsonb_array_elements(v_content) d
        where nullif(d->>'url_documento','') is not null
        on conflict (codigo_proceso, url_documento) do nothing;
        get diagnostics n = row_count;
        n_doc := n_doc + n;
      end if;

      update public.dgcp_procesos set documentos_traidos_en = now()
      where codigo_proceso = r.codigo_proceso;
      n_proc := n_proc + 1;
    exception when others then
      n_err := n_err + 1;
    end;
  end loop;
  return query select n_proc, n_doc, n_err;
end $$;

create or replace function public.dgcp_traer_contratos(limite integer default 150)
returns table (procesos_revisados integer, contratos integer, fallos integer)
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r record; v_resp jsonb; v_content jsonb;
  n_proc integer := 0; n_con integer := 0; n_err integer := 0; n integer;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '45');
  for r in
    select codigo_proceso from public.dgcp_procesos
    where objeto_proceso = 'Obras' and contratos_traidos_en is null
    order by fecha_publicacion desc limit limite
  loop
    begin
      v_resp := (extensions.http_get(
        'https://datosabiertos.dgcp.gob.do/api-dgcp/v1/contratos?limit=100&proceso='
        || extensions.urlencode(r.codigo_proceso))).content::jsonb;

      if coalesce((v_resp->>'hasError')::boolean, false) then
        raise exception 'DGCP: %', coalesce(v_resp #>> '{payload,message}', 'error');
      end if;

      v_content := v_resp #> '{payload,content}';
      if v_content is not null and jsonb_typeof(v_content) = 'array' then
        insert into public.dgcp_contratos as d (
          codigo_contrato, codigo_proceso, codigo_unidad_compra, unidad_compra,
          rpe, razon_social, estado_contrato, estado_adjudicacion, descripcion,
          divisa, valor_contratado, metodo_pago, plazo_pago_factura,
          fecha_adjudicacion, fecha_creacion_contrato, url_contrato, sincronizado_en)
        select
          trim(c->>'codigo_contrato'), c->>'codigo_proceso',
          public.dgcp_int(c->>'codigo_unidad_compra'), c->>'unidad_compra',
          public.dgcp_int(c->>'rpe'), c->>'razon_social',
          c->>'estado_contrato', c->>'estado_adjudicacion', c->>'descripcion',
          c->>'divisa',
          case when jsonb_typeof(c->'valor_contratado') = 'number'
               then (c->>'valor_contratado')::numeric end,
          c->>'metodo_pago', c->>'plazo_pago_factura',
          public.dgcp_ts(c->>'fecha_adjudicacion'),
          public.dgcp_ts(c->>'fecha_creacion_contrato'),
          c->>'url_contrato', now()
        from jsonb_array_elements(v_content) c
        where nullif(trim(c->>'codigo_contrato'),'') is not null
        on conflict (codigo_contrato) do update set
          estado_contrato = excluded.estado_contrato,
          estado_adjudicacion = excluded.estado_adjudicacion,
          valor_contratado = excluded.valor_contratado,
          sincronizado_en = now();
        get diagnostics n = row_count;
        n_con := n_con + n;
      end if;

      update public.dgcp_procesos set contratos_traidos_en = now()
      where codigo_proceso = r.codigo_proceso;
      n_proc := n_proc + 1;
    exception when others then
      n_err := n_err + 1;
    end;
  end loop;
  return query select n_proc, n_con, n_err;
end $$;

create or replace function public.dgcp_traer_pacc()
returns integer language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare v_resp jsonb; v_content jsonb; v_pag integer; v_total integer := 1; n integer := 0; m integer;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '90');
  v_pag := 1;
  loop
    v_resp := (extensions.http_get(
      'https://datosabiertos.dgcp.gob.do/api-dgcp/v1/pacc?limit=1000&page=' || v_pag)).content::jsonb;
    v_total := coalesce((v_resp->>'pages')::int, 1);
    v_content := v_resp #> '{payload,content}';
    exit when v_content is null or jsonb_array_length(v_content) = 0;

    insert into public.dgcp_pacc as d (
      uid_pacc, codigo_unidad_compra, unidad_compra, periodo, version,
      responsable, correo_responsable, fecha_publicacion, url, sincronizado_en)
    select
      trim(p->>'uid_pacc'), public.dgcp_int(p->>'codigo_unidad_compra'),
      p->>'unidad_compra', public.dgcp_int(p->>'periodo'), p->>'version',
      p->>'responsable', p->>'correo_responsable',
      public.dgcp_ts(p->>'fecha_publicacion'), p->>'url', now()
    from jsonb_array_elements(v_content) p
    where nullif(trim(p->>'uid_pacc'),'') is not null
    on conflict (uid_pacc) do update set
      version = excluded.version,
      fecha_publicacion = excluded.fecha_publicacion,
      url = excluded.url, sincronizado_en = now();
    get diagnostics m = row_count;
    n := n + m;

    v_pag := v_pag + 1;
    exit when v_pag > v_total or v_pag > 20;
  end loop;
  return n;
end $$;

create or replace function public.dgcp_sincronizar_complementos(
  limite_documentos integer default 120,
  limite_contratos  integer default 120,
  con_pacc          boolean default false
)
returns table (documentos integer, contratos integer, pacc integer, fallos integer)
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare d record; c record; n_pacc integer := 0;
begin
  select * into d from public.dgcp_traer_documentos(limite_documentos);
  select * into c from public.dgcp_traer_contratos(limite_contratos);
  if con_pacc then n_pacc := public.dgcp_traer_pacc(); end if;
  return query select d.documentos, c.contratos, n_pacc, d.fallos + c.fallos;
end $$;

-- ============================================================
-- Vistas que consulta la aplicación
-- ============================================================
create or replace view public.v_competencia
with (security_invoker = true) as
select
  c.rpe, c.razon_social,
  count(*)                               as contratos_ganados,
  sum(c.valor_contratado)                as valor_total,
  round(avg(c.valor_contratado))         as valor_promedio,
  max(c.valor_contratado)                as contrato_mayor,
  min(c.fecha_adjudicacion)::date        as primera_adjudicacion,
  max(c.fecha_adjudicacion)::date        as ultima_adjudicacion,
  count(distinct c.codigo_unidad_compra) as instituciones,
  array_agg(distinct coalesce(u.acronimo, c.unidad_compra))
    filter (where c.unidad_compra is not null) as donde_gana
from public.dgcp_contratos c
left join public.dgcp_unidades_compra u on u.codigo_unidad_compra = c.codigo_unidad_compra
where c.rpe is not null
group by c.rpe, c.razon_social;
comment on view public.v_competencia is
  'Perfil de cada contratista que gana obras públicas: cuántas, por cuánto y en qué instituciones.';

create or replace view public.v_oportunidades
with (security_invoker = true) as
select
  o.id, o.estado as seguimiento, o.responsable, o.monto_ofertado,
  o.motivo_descarte, o.notas,
  p.codigo_proceso, p.titulo, p.descripcion, p.modalidad, p.estado_proceso,
  p.monto_estimado, p.divisa, p.fecha_publicacion,
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
  adj.razon_social                                               as adjudicado_a,
  adj.valor_contratado                                           as valor_adjudicado
from public.oportunidades o
join public.dgcp_procesos p             on p.codigo_proceso = o.codigo_proceso
left join public.dgcp_unidades_compra u on u.codigo_unidad_compra = p.codigo_unidad_compra
left join lateral (
  select c.razon_social, c.valor_contratado
  from public.dgcp_contratos c
  where c.codigo_proceso = p.codigo_proceso
  order by c.valor_contratado desc nulls last
  limit 1
) adj on true;
comment on view public.v_oportunidades is
  'Obras de la DGCP con el seguimiento de JMC, sus pliegos y, si ya cerró, quién la ganó.';

-- ============================================================
-- Permisos
-- ============================================================
alter table public.dgcp_unidades_compra enable row level security;
alter table public.dgcp_procesos        enable row level security;
alter table public.dgcp_documentos      enable row level security;
alter table public.dgcp_contratos       enable row level security;
alter table public.dgcp_pacc            enable row level security;
alter table public.dgcp_sync            enable row level security;
alter table public.oportunidades        enable row level security;

-- Datos públicos de la DGCP: los lee cualquiera que entre a la plataforma.
drop policy if exists unidades_lectura   on public.dgcp_unidades_compra;
drop policy if exists procesos_lectura   on public.dgcp_procesos;
drop policy if exists documentos_lectura on public.dgcp_documentos;
drop policy if exists contratos_lectura  on public.dgcp_contratos;
drop policy if exists pacc_lectura       on public.dgcp_pacc;
create policy unidades_lectura   on public.dgcp_unidades_compra for select to authenticated using (true);
create policy procesos_lectura   on public.dgcp_procesos        for select to authenticated using (true);
create policy documentos_lectura on public.dgcp_documentos      for select to authenticated using (true);
create policy contratos_lectura  on public.dgcp_contratos       for select to authenticated using (true);
create policy pacc_lectura       on public.dgcp_pacc            for select to authenticated using (true);

drop policy if exists unidades_marcar_seguida on public.dgcp_unidades_compra;
create policy unidades_marcar_seguida on public.dgcp_unidades_compra
  for update to authenticated
  using      (public.current_user_role() in ('administrador','director','gerente_licitaciones'))
  with check (public.current_user_role() in ('administrador','director','gerente_licitaciones'));

drop policy if exists sync_lectura on public.dgcp_sync;
create policy sync_lectura on public.dgcp_sync
  for select to authenticated
  using (public.current_user_role() in ('administrador','director','gerente_licitaciones'));

drop policy if exists oportunidades_lectura on public.oportunidades;
create policy oportunidades_lectura on public.oportunidades
  for select to authenticated using (true);

drop policy if exists oportunidades_escritura on public.oportunidades;
create policy oportunidades_escritura on public.oportunidades
  for all to authenticated
  using      (public.current_user_role() in ('administrador','director','gerente_licitaciones','presupuesto'))
  with check (public.current_user_role() in ('administrador','director','gerente_licitaciones','presupuesto'));

grant select on public.v_oportunidades to authenticated;
grant select on public.v_competencia   to authenticated;

-- IMPORTANTE: en Postgres toda función nace con execute para PUBLIC, y anon
-- hereda de ahí. Revocar de anon NO basta — hay que revocar de PUBLIC.
-- Sin esto, cualquiera sin iniciar sesión podría inyectar licitaciones falsas.
revoke execute on function public.dgcp_cargar_procesos(jsonb) from public;
revoke execute on function public.dgcp_cargar_unidades(jsonb) from public;
revoke execute on function public.dgcp_traer_documentos(integer) from public;
revoke execute on function public.dgcp_traer_contratos(integer)  from public;
revoke execute on function public.dgcp_traer_pacc()              from public;
revoke execute on function public.dgcp_sincronizar(date,integer,integer,boolean,integer) from public;
revoke execute on function public.dgcp_sincronizar_complementos(integer,integer,boolean) from public;
revoke execute on function public.dgcp_ts(text)   from public;
revoke execute on function public.dgcp_sino(text) from public;
revoke execute on function public.dgcp_int(text)  from public;

-- Instituciones donde JMC suele competir.
update public.dgcp_unidades_compra set seguida = true
where acronimo in ('ETED','ISFODOSU','INABIMA','INESDYC','INAPA','EDESUR','EDENORTE','EDEESTE','MOPC','INVI','CAASD')
   or unidad_compra ilike '%ayuntamiento%';
