// Supabase Edge Function: odoo-sync
//
// Copies a verified-on-server attendance event into Odoo (hr.attendance).
// The Odoo password stays on the server. It is never shipped in the app.
//
// Deploy:
//   npx supabase functions deploy odoo-sync --project-ref <your-project-ref>
//   npx supabase secrets set ODOO_URL=https://... ODOO_DB=... ODOO_USER=... ODOO_PASSWORD=... --project-ref <your-project-ref>
//
// Called by the app with the signed-in user's token:
//   POST /functions/v1/odoo-sync   { "event_id": "<attendance_events.id>" }

import { createClient } from 'jsr:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

// Odoo expects UTC as "YYYY-MM-DD HH:MM:SS".
function odooTime(iso: string): string {
  return new Date(iso).toISOString().replace('T', ' ').split('.')[0]
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ ok: false, error: 'Use POST' }, 405)

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } })

  // 1. Who is calling?
  const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  const { data: userData, error: userError } = await admin.auth.getUser(jwt)
  const user = userData?.user
  if (userError || !user) return json({ ok: false, error: 'Not signed in' }, 401)

  let eventId = ''
  try {
    eventId = String((await req.json())?.event_id ?? '')
  } catch {
    return json({ ok: false, error: 'Body must be JSON with event_id' }, 400)
  }
  if (!eventId) return json({ ok: false, error: 'event_id is required' }, 400)

  // 2. Load the event; only its owner (or a manager) may sync it.
  const { data: event, error: eventError } = await admin
    .from('attendance_events')
    .select('*')
    .eq('id', eventId)
    .maybeSingle()
  if (eventError || !event) return json({ ok: false, error: 'Attendance record not found' }, 404)

  const { data: caller } = await admin
    .from('profiles')
    .select('role')
    .eq('user_id', user.id)
    .maybeSingle()
  if (event.user_id !== user.id && caller?.role !== 'admin') {
    return json({ ok: false, error: 'Not allowed' }, 403)
  }
  if (event.odoo_synced) return json({ ok: true, alreadySynced: true })

  const ODOO_URL = (Deno.env.get('ODOO_URL') ?? '').replace(/\/+$/, '')
  const ODOO_DB = Deno.env.get('ODOO_DB') ?? ''
  const ODOO_USER = Deno.env.get('ODOO_USER') ?? ''
  const ODOO_PASSWORD = Deno.env.get('ODOO_PASSWORD') ?? ''
  if (!ODOO_URL || !ODOO_DB || !ODOO_USER || !ODOO_PASSWORD) {
    return json({ ok: false, skipped: true, error: 'Odoo is not configured' })
  }

  const markError = async (message: string) => {
    await admin.from('attendance_events').update({ odoo_error: message.slice(0, 500) }).eq('id', eventId)
  }

  try {
    // 3. Log in to Odoo.
    const authRes = await fetch(`${ODOO_URL}/web/session/authenticate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        params: { db: ODOO_DB, login: ODOO_USER, password: ODOO_PASSWORD },
      }),
    })
    const authData = await authRes.json()
    if (authData.error) {
      throw new Error(`Odoo login failed: ${authData.error.data?.message ?? authData.error.message}`)
    }
    const cookie = authRes.headers.get('set-cookie')?.split(';')[0]
    if (!cookie) throw new Error('Odoo did not return a session')

    const call = async (model: string, method: string, args: unknown[], kwargs: Record<string, unknown> = {}) => {
      const res = await fetch(`${ODOO_URL}/web/dataset/call_kw`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Cookie: cookie },
        body: JSON.stringify({ jsonrpc: '2.0', params: { model, method, args, kwargs } }),
      })
      const data = await res.json()
      if (data.error) {
        throw new Error(`Odoo ${model}.${method} failed: ${data.error.data?.message ?? data.error.message}`)
      }
      return data.result
    }

    // 4. Find the employee by work email, then by name.
    const { data: profile } = await admin
      .from('profiles')
      .select('full_name, email')
      .eq('user_id', event.user_id)
      .maybeSingle()

    let employeeId: number | null = null
    const email = profile?.email ?? ''
    if (email) {
      const ids = await call('hr.employee', 'search', [[['work_email', '=ilike', email]]], { limit: 1 })
      if (Array.isArray(ids) && ids.length) employeeId = ids[0]
    }
    const name = profile?.full_name ?? event.staff_name ?? ''
    if (!employeeId && name) {
      const ids = await call('hr.employee', 'search', [[['name', 'ilike', name]]], { limit: 1 })
      if (Array.isArray(ids) && ids.length) employeeId = ids[0]
    }
    if (!employeeId) throw new Error(`No Odoo employee matches ${email || name}`)

    // 5. Write the attendance using the server's timestamp.
    const time = odooTime(event.server_time)
    if (event.event_type === 'clock_in') {
      await call('hr.attendance', 'create', [{ employee_id: employeeId, check_in: time }])
    } else {
      const open = await call(
        'hr.attendance',
        'search',
        [[['employee_id', '=', employeeId], ['check_out', '=', false]]],
        { limit: 1, order: 'check_in desc' },
      )
      if (!Array.isArray(open) || !open.length) throw new Error('No open Odoo check-in to close')
      await call('hr.attendance', 'write', [[open[0]], { check_out: time }])
    }

    await admin.from('attendance_events').update({ odoo_synced: true, odoo_error: null }).eq('id', eventId)
    return json({ ok: true })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('odoo-sync:', message)
    await markError(message)
    return json({ ok: false, error: message }, 502)
  }
})
