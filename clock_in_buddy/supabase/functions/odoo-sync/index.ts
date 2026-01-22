// Setup type definitions for Deno
/// <reference lib="deno.ns" />

const ODOO_URL = Deno.env.get('ODOO_URL') ?? ''
const ODOO_DB = Deno.env.get('ODOO_DB') ?? ''
const ODOO_USER = Deno.env.get('ODOO_USER') ?? ''
const ODOO_PASSWORD = Deno.env.get('ODOO_PASSWORD') ?? ''

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { phone, name, eventType, lat, lng, address } = await req.json()

    if (!ODOO_URL || !ODOO_DB || !ODOO_USER || !ODOO_PASSWORD) {
      throw new Error('Server misconfigured: Missing Odoo environment variables')
    }

    // 1. Authenticate with Odoo
    console.log(`Authenticating with Odoo: ${ODOO_URL}`)
    const authRes = await fetch(`${ODOO_URL}/web/session/authenticate`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: "2.0",
        params: {
          db: ODOO_DB,
          login: ODOO_USER,
          password: ODOO_PASSWORD,
        }
      })
    })

    const authData = await authRes.json()
    if (authData.error) {
      throw new Error(`Odoo Auth Failed: ${authData.error.data?.message || authData.error.message}`)
    }

    const sessionId = authRes.headers.get('set-cookie')?.split(';')[0]
    if (!sessionId) {
      throw new Error('Did not receive session ID from Odoo')
    }

    // 2. Find Employee
    console.log(`Looking up employee - Phone: ${phone}, Name: ${name}`)
    
    // Helper for Odoo calls
    const odooCall = async (model: string, method: string, args: any[], kwargs = {}) => {
      const res = await fetch(`${ODOO_URL}/web/dataset/call_kw`, {
        method: 'POST',
        headers: { 
          'Content-Type': 'application/json',
          'Cookie': sessionId
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          params: {
            model,
            method,
            args,
            kwargs
          }
        })
      })
      const data = await res.json()
      if (data.error) {
        throw new Error(`Odoo Call Failed (${model}.${method}): ${data.error.data?.message || data.error.message}`)
      }
      return data.result
    }

    let employeeId: number | null = null

    // Search logic similar to Dart service
    if (phone) {
      const last9 = phone.replace(/\D/g, '').slice(-9)
      const phoneDomain = [
        '|', ['work_phone', 'ilike', `%${last9}%`],
        '|', ['mobile_phone', 'ilike', `%${last9}%`],
        ['private_phone', 'ilike', `%${last9}%`]
      ]
      const results = await odooCall('hr.employee', 'search', [phoneDomain])
      if (results?.length > 0) employeeId = results[0]
    }

    if (!employeeId && name) {
      const results = await odooCall('hr.employee', 'search', [[['name', 'ilike', `%${name}%`]]])
      if (results?.length > 0) employeeId = results[0]
    }

    if (!employeeId) {
      return new Response(JSON.stringify({ success: false, error: 'Employee not found in Odoo' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 404
      })
    }

    // 3. Sync Clock Event
    const now = new Date().toISOString().replace('T', ' ').split('.')[0] // YYYY-MM-DD HH:MM:SS
    
    if (eventType === 'clock_in') {
      await odooCall('hr.attendance', 'create', [{
        employee_id: employeeId,
        check_in: now,
      }])
    } else {
      // Find open attendance
      const attendanceIds = await odooCall('hr.attendance', 'search', [[
        ['employee_id', '=', employeeId],
        ['check_out', '=', false]
      ]], { limit: 1 })

      if (attendanceIds?.length > 0) {
        await odooCall('hr.attendance', 'write', [
          attendanceIds[0],
          { check_out: now }
        ])
      } else {
        throw new Error('No open clock-in record found to clock out from')
      }
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200
    })

  } catch (error: any) {
    console.error('Edge Function Error:', error)
    return new Response(JSON.stringify({ success: false, error: error.message || 'Internal Server Error' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400
    })
  }
})
