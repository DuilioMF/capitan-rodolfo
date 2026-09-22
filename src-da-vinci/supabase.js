import { createClient } from '@supabase/supabase-js'

// Misma conexión PostgreSQL/Supabase usada por Supervisión.
// La clave es publicable; nunca se expone la contraseña del PostgreSQL.
export const supabase = createClient(
  'https://apqgrwudkfytwikrsivd.supabase.co',
  'sb_publishable_B9NdjnzOKu9BhZGmTM6LGg_wDB3n8lY',
  { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } },
)
