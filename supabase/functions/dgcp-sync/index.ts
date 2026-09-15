// Disparador manual de la sincronización con la DGCP.
//
// El trabajo real lo hace public.dgcp_sincronizar() DENTRO de la base (ver
// supabase/migrations/0002_dgcp_ingesta.sql), que además corre sola cada 3
// horas por pg_cron. Esta función solo existe para poder forzar una corrida
// desde fuera — un botón en la plataforma, por ejemplo.
//
//   POST /functions/v1/dgcp-sync
//   Authorization: Bearer <SERVICE_ROLE_KEY>
//   body opcional: { "desde": "2026-01-01", "max_paginas": 12, "pagina_inicial": 1 }
//
// Desplegar:  supabase functions deploy dgcp-sync

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

Deno.serve(async (req) => {
  const clave = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (req.headers.get("Authorization") !== `Bearer ${clave}`) {
    return Response.json({ error: "No autorizado" }, { status: 401 });
  }

  const b = await req.json().catch(() => ({}));
  const db = createClient(Deno.env.get("SUPABASE_URL")!, clave);

  const { data, error } = await db.rpc("dgcp_sincronizar", {
    desde: b.desde ?? null,
    max_paginas: b.max_paginas ?? 12,
    por_pagina: b.por_pagina ?? 500,
    incluir_unidades: b.incluir_unidades ?? true,
    pagina_inicial: b.pagina_inicial ?? 1,
  });

  if (error) return Response.json({ ok: false, error: error.message }, { status: 500 });
  return Response.json({ ok: true, ...(Array.isArray(data) ? data[0] : data) });
});
