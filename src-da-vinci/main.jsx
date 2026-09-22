import React, { useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { supabase } from './supabase'
import './styles.css'

const SQL_BRIDGE = 'http://127.0.0.1:8787'

function Mark() {
  return <div className="mark" aria-hidden="true"><span>D</span><i /><b>V</b></div>
}

function WorldCard({ kind, eyebrow, title, copy, meta, onClick }) {
  return <button className={`world-card ${kind}`} onClick={onClick}>
    <span className="orbit" aria-hidden="true" />
    <span className="card-number">{kind === 'rodolfo' ? '01' : '02'}</span>
    <span className="card-copy"><small>{eyebrow}</small><strong>{title}</strong><em>{copy}</em><span className="meta"><i />{meta}</span></span>
    <span className="enter">INGRESAR <b>↗</b></span>
  </button>
}

function Field({ label, children }) { return <label className="field"><span>{label}</span>{children}</label> }

function SqlPanel({ onBack }) {
  const [server, setServer] = useState(localStorage.getItem('rodolfo-sql-server') || 'DUILIO\\SQLEXPRESS')
  const [user, setUser] = useState(localStorage.getItem('rodolfo-sql-user') || '')
  const [password, setPassword] = useState('')
  const [status, setStatus] = useState({ type: '', text: 'Bridge local listo para verificar.' })
  const [busy, setBusy] = useState(false)
  async function testBridge() {
    setBusy(true); setStatus({ type: 'working', text: 'Buscando el bridge SQL local…' })
    try {
      const response = await fetch(`${SQL_BRIDGE}/health`, { signal: AbortSignal.timeout(4500) })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      localStorage.setItem('rodolfo-sql-server', server.trim()); localStorage.setItem('rodolfo-sql-user', user.trim())
      sessionStorage.setItem('rodolfo-sql-draft', JSON.stringify({ server: server.trim(), user: user.trim() }))
      setPassword(''); setStatus({ type: 'ok', text: 'Bridge encontrado. Abrí la conexión completa para elegir la base.' })
    } catch { setStatus({ type: 'error', text: 'No encuentro el bridge. Ejecutá INICIAR_CAPITAN_RODOLFO.bat en esta PC.' }) }
    finally { setBusy(false) }
  }
  return <ConnectionShell accent="orange" code="SQL SERVER · ESTACIONES" title="Capitán Rodolfo" onBack={onBack}>
    <p className="panel-lead">Conectá la estación. Después elegís la base <b>SisRL</b>, sus tablas y el circuito vivo.</p>
    <div className="form-grid">
      <Field label="Servidor"><input value={server} onChange={e => setServer(e.target.value)} /></Field>
      <Field label="Usuario"><input value={user} onChange={e => setUser(e.target.value)} autoComplete="username" /></Field>
      <Field label="Contraseña"><input type="password" value={password} onChange={e => setPassword(e.target.value)} autoComplete="current-password" placeholder="No se guarda" /></Field>
    </div>
    <Status {...status} />
    <div className="panel-actions"><button className="action ghost" onClick={testBridge} disabled={busy}>{busy ? 'VERIFICANDO…' : 'VERIFICAR BRIDGE'}</button><a className="action primary" href="conexion-sql.html">CONECTAR Y ELEGIR BASE <span>→</span></a></div>
  </ConnectionShell>
}

function RubenPanel({ onBack }) {
  const [email, setEmail] = useState(''); const [password, setPassword] = useState('')
  const [status, setStatus] = useState({ type: '', text: 'Conexión PostgreSQL heredada de Supervisión.' }); const [busy, setBusy] = useState(false)
  async function connect(event) {
    event.preventDefault()
    if (!email || !password) return setStatus({ type: 'error', text: 'Completá email y contraseña.' })
    setBusy(true); setStatus({ type: 'working', text: 'Abriendo el taller de Ruben…' })
    const { data, error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    setPassword(''); setBusy(false)
    if (error) return setStatus({ type: 'error', text: error.message })
    setStatus({ type: 'ok', text: `PostgreSQL conectado. Bienvenido ${data.user?.email || ''}.` })
  }
  return <ConnectionShell accent="cyan" code="POSTGRESQL · SINIESTROS" title="Ruben" onBack={onBack}>
    <p className="panel-lead">Un caso entra como siniestro y sale reparado, facturado y cobrado. Esta puerta usa la conexión segura de Supervisión.</p>
    <form onSubmit={connect}><div className="form-grid">
      <Field label="Correo electrónico"><input type="email" value={email} onChange={e => setEmail(e.target.value)} autoComplete="username" /></Field>
      <Field label="Contraseña"><input type="password" value={password} onChange={e => setPassword(e.target.value)} autoComplete="current-password" /></Field>
      <div className="route-preview"><span>SINIESTRO</span><i /><span>REPARACIÓN</span><i /><span>COBRANZA</span></div>
    </div><Status {...status} /><div className="panel-actions"><button className="action primary cyan" disabled={busy}>{busy ? 'CONECTANDO…' : 'CONECTAR A POSTGRESQL'} <span>→</span></button></div></form>
  </ConnectionShell>
}

function Status({ type, text }) { return <div className={`status ${type}`}><i />{text}</div> }

function ConnectionShell({ accent, code, title, onBack, children }) {
  return <main className={`connection-view ${accent}`}><div className="blueprint" aria-hidden="true" /><header><button className="back" onClick={onBack}>← VOLVER A LOS MUNDOS</button><span>DOINGLIO / DA VINCI</span></header><section className="connection-layout"><aside><Mark /><span className="vertical-code">{code}</span><div className="figure"><span className="head" /><span className="body" /><i className="measure one" /><i className="measure two" /></div></aside><article className="connection-panel"><small>{code}</small><h1>{title}</h1>{children}</article></section></main>
}

function Portal() {
  const [world, setWorld] = useState(null)
  const particles = useMemo(() => Array.from({ length: 28 }, (_, i) => <i key={i} style={{ '--x': `${(i * 37) % 100}%`, '--y': `${(i * 61) % 100}%`, '--d': `${5 + (i % 8)}s` }} />), [])
  if (world === 'rodolfo') return <SqlPanel onBack={() => setWorld(null)} />
  if (world === 'ruben') return <RubenPanel onBack={() => setWorld(null)} />
  return <main className="portal"><div className="particles" aria-hidden="true">{particles}</div><div className="drawing drawing-left" aria-hidden="true"><span /><i /><b /></div><div className="drawing drawing-right" aria-hidden="true"><span /><i /><b /></div><header className="topbar"><div className="brand"><Mark /><span><b>DOINGLIO</b><small>INTELIGENCIA EN MOVIMIENTO</small></span></div><span className="version">EXPERIENCIA DA VINCI · v37</span></header><section className="hero"><small>TODO SISTEMA TIENE UN ALMA</small><h1>Elegí el mundo<br />que querés <em>despertar.</em></h1><p>Dos inteligencias. Dos conexiones. Un mismo universo vivo.</p></section><section className="worlds"><WorldCard kind="rodolfo" eyebrow="ESTACIONES DE SERVICIO" title="Capitán Rodolfo" copy="La estación respira: combustible, surtidores, ventas y cobros en un solo pulso." meta="SQL SERVER · BRIDGE LOCAL" onClick={() => setWorld('rodolfo')} /><WorldCard kind="ruben" eyebrow="TALLERES Y ASEGURADORAS" title="Ruben" copy="Cada siniestro encuentra su camino: autorización, reparación, factura y cobranza." meta="POSTGRESQL · SUPERVISIÓN" onClick={() => setWorld('ruben')} /></section><footer><span>REVALSOFT IA</span><i /><span>DISEÑADO PARA VER LO INVISIBLE</span></footer></main>
}

createRoot(document.getElementById('root')).render(<React.StrictMode><Portal /></React.StrictMode>)
