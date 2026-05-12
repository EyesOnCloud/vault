import os
import time
import logging
import psycopg2
import hvac
from flask import Flask, jsonify

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

def get_password_from_env():
    """
    Phase 1: Insecure baseline.
    Password comes from an environment variable set in docker-compose.
    Anyone with access to the container, the compose file, or the deployment
    manifest can read this password in plaintext.
    """
    password = os.environ.get('DB_PASSWORD')
    if not password:
        raise ValueError("DB_PASSWORD environment variable is not set")
    logger.info("[ENV MODE] Retrieved database password from environment variable")
    logger.warning("[ENV MODE] WARNING: Password visible in container environment, compose file, and process list")
    return password

def get_password_from_vault():
    """
    Phase 2: Vault-integrated retrieval.
    The application authenticates to Vault using a token and reads the
    secret from the KV secrets engine. The actual password never appears
    in any configuration file, environment variable, or deployment manifest.
    """
    vault_addr = os.environ.get('VAULT_ADDR', 'http://vault:8200')
    vault_token = os.environ.get('VAULT_TOKEN')
    secret_path = os.environ.get('VAULT_SECRET_PATH', 'secret/data/db')

    if not vault_token:
        raise ValueError("VAULT_TOKEN environment variable is not set")

    logger.info(f"[VAULT MODE] Connecting to Vault at {vault_addr}")

    client = hvac.Client(url=vault_addr, token=vault_token)

    if not client.is_authenticated():
        raise Exception("Vault authentication failed — check VAULT_TOKEN")

    logger.info(f"[VAULT MODE] Authenticated to Vault successfully")
    logger.info(f"[VAULT MODE] Reading secret from path: {secret_path}")

    # Parse the path — hvac KV v2 uses mount_point + path format
    path_parts = secret_path.replace('secret/data/', '')
    secret = client.secrets.kv.v2.read_secret_version(
        path=path_parts,
        mount_point='secret'
    )

    password = secret['data']['data']['password']
    logger.info(f"[VAULT MODE] Secret retrieved successfully from Vault")
    logger.info(f"[VAULT MODE] Secret version: {secret['data']['metadata']['version']}")
    return password

def get_db_password():
    """
    Router function — switches between env and vault mode based on APP_MODE.
    In production, you would remove env mode entirely and only use Vault.
    """
    mode = os.environ.get('APP_MODE', 'env')
    if mode == 'vault':
        return get_password_from_vault()
    else:
        return get_password_from_env()

def get_db_connection():
    password = get_db_password()
    return psycopg2.connect(
        host=os.environ['DB_HOST'],
        port=int(os.environ.get('DB_PORT', 5432)),
        dbname=os.environ['DB_NAME'],
        user=os.environ['DB_USER'],
        password=password
    )

@app.route('/health')
def health():
    return jsonify({"status": "ok", "mode": os.environ.get('APP_MODE', 'env')}), 200

@app.route('/db-check')
def db_check():
    """
    Connects to the database, retrieves the password from the configured
    source (env or vault), and returns connection status.
    This endpoint is the proof that the integration works end-to-end.
    """
    start_time = time.time()
    try:
        mode = os.environ.get('APP_MODE', 'env')
        logger.info(f"[DB CHECK] Starting database connection check in {mode} mode")

        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT version(), current_database(), current_user, now()")
        row = cursor.fetchone()
        cursor.close()
        conn.close()

        elapsed = round((time.time() - start_time) * 1000, 2)

        return jsonify({
            "status": "connected",
            "mode": mode,
            "postgres_version": row[0].split(' ')[0] + ' ' + row[1],
            "database": row[1],
            "connected_as": row[2],
            "server_time": str(row[3]),
            "retrieval_time_ms": elapsed,
            "message": f"Password retrieved from {'Vault' if mode == 'vault' else 'environment variable'}"
        }), 200

    except Exception as e:
        elapsed = round((time.time() - start_time) * 1000, 2)
        logger.error(f"[DB CHECK] Connection failed: {str(e)}")
        return jsonify({
            "status": "failed",
            "error": str(e),
            "retrieval_time_ms": elapsed
        }), 500

@app.route('/secret-info')
def secret_info():
    """
    Returns metadata about the current secret version in Vault.
    Demonstrates Vault's versioning capability without exposing the actual value.
    Only available in vault mode.
    """
    mode = os.environ.get('APP_MODE', 'env')
    if mode != 'vault':
        return jsonify({
            "error": "This endpoint only works in vault mode",
            "current_mode": mode
        }), 400

    vault_addr = os.environ.get('VAULT_ADDR', 'http://vault:8200')
    vault_token = os.environ.get('VAULT_TOKEN')
    client = hvac.Client(url=vault_addr, token=vault_token)

    secret = client.secrets.kv.v2.read_secret_version(
        path='db',
        mount_point='secret'
    )

    metadata = secret['data']['metadata']
    return jsonify({
        "secret_path": "secret/db",
        "current_version": metadata['version'],
        "created_time": str(metadata['created_time']),
        "deletion_time": str(metadata.get('deletion_time', 'never')),
        "destroyed": metadata.get('destroyed', False),
        "note": "Actual secret value is NOT returned by this endpoint"
    }), 200

if __name__ == '__main__':
    logger.info(f"Starting application in {os.environ.get('APP_MODE', 'env')} mode")
    app.run(host='0.0.0.0', port=8080, debug=False)
