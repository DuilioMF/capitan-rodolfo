from flask import Flask, request, jsonify, make_response
import pyodbc, uuid
from urllib.parse import urlparse

app = Flask(__name__)
sessions = {}

ALLOWED_ORIGINS = {
    "https://rodolfo.doinglio.com.ar",
    "https://doinglio.com.ar",
    "https://doinglio.revalsoftia.chatgpt.site",
    "https://doinglio.revalsoftia.com.ar",
    "null",
}

def origin_allowed(origin):
    if origin in ALLOWED_ORIGINS:
        return True
    try:
        host = (urlparse(origin).hostname or "").lower()
    except Exception:
        return False
    return (
        host in {"127.0.0.1", "localhost"}
        or host.endswith(".doinglio.com.ar")
        or host.endswith(".revalsoftia.com.ar")
        or host.endswith(".revalsoftia.chatgpt.site")
        or host.endswith(".duiliofracchia.workers.dev")
    )

def cors(resp):
    origin = request.headers.get("Origin", "")
    if origin_allowed(origin):
        resp.headers["Access-Control-Allow-Origin"] = origin
    resp.headers["Vary"] = "Origin"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    resp.headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
    resp.headers["Access-Control-Allow-Private-Network"] = "true"
    return resp

@app.after_request
def after(resp):
    return cors(resp)

@app.route("/<path:path>", methods=["OPTIONS"])
@app.route("/", methods=["OPTIONS"])
def options(path=None):
    return make_response("", 204)

def driver_name():
    drivers = pyodbc.drivers()
    preferred = ["ODBC Driver 18 for SQL Server", "ODBC Driver 17 for SQL Server", "SQL Server"]
    for name in preferred:
        if name in drivers:
            return name
    raise RuntimeError("No se encontró un driver ODBC de SQL Server. Instalá Microsoft ODBC Driver 18.")

@app.get("/health")
def health():
    return jsonify({"ok": True, "service": "DoingLio SQL Bridge", "version": "16"})

@app.post("/api/connect")
def connect():
    data = request.get_json(silent=True) or {}
    server = (data.get("server") or "").strip()
    user = (data.get("user") or "").strip()
    password = data.get("password") or ""
    if not server or not user or not password:
        return jsonify({"error": "Completá servidor, usuario y contraseña."}), 400
    try:
        drv = driver_name()
        cs = (
            f"DRIVER={{{drv}}};"
            f"SERVER={server};UID={user};PWD={password};"
            "Encrypt=yes;TrustServerCertificate=yes;"
            "Connection Timeout=7;"
        )
        cn = pyodbc.connect(cs, autocommit=True)
        cur = cn.cursor()
        cur.execute("""
            SELECT name
            FROM sys.databases
            WHERE state_desc='ONLINE' AND HAS_DBACCESS(name)=1
            ORDER BY name
        """)
        dbs = [r[0] for r in cur.fetchall()]
        sid = str(uuid.uuid4())
        sessions[sid] = {"connection": cn, "databases": set(dbs), "server": server}
        return jsonify({"sessionId": sid, "server": server, "databases": dbs})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.post("/api/tables")
def tables():
    data = request.get_json(silent=True) or {}
    sid = data.get("sessionId")
    database = data.get("database")
    s = sessions.get(sid)
    if not s:
        return jsonify({"error": "Sesión vencida. Volvé a conectar."}), 401
    if database not in s["databases"]:
        return jsonify({"error": "Base no autorizada para esta sesión."}), 403
    try:
        safe_db = database.replace("]", "]]")
        cur = s["connection"].cursor()
        cur.execute(f"USE [{safe_db}]")
        cur.execute("""
            SELECT TABLE_SCHEMA, TABLE_NAME
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_TYPE='BASE TABLE'
            ORDER BY TABLE_SCHEMA, TABLE_NAME
        """)
        rows = [{"schema": r[0], "name": r[1]} for r in cur.fetchall()]
        return jsonify({"database": database, "tables": rows})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8787, debug=False, threaded=True)
