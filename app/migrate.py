import os

import psycopg2

POSTGRES_DSN = os.environ["POSTGRES_DSN"]
MIGRATIONS_DIR = os.path.join(os.path.dirname(__file__), "migrations")


def main() -> None:
    conn = psycopg2.connect(POSTGRES_DSN, connect_timeout=5)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations ("
        "id TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())"
    )
    cur.execute("SELECT id FROM schema_migrations")
    applied = {row[0] for row in cur.fetchall()}

    for name in sorted(os.listdir(MIGRATIONS_DIR)):
        if not name.endswith(".sql") or name in applied:
            continue
        with open(os.path.join(MIGRATIONS_DIR, name)) as f:
            sql = f.read()
        print(f"Applying migration {name}")
        cur.execute(sql)
        cur.execute("INSERT INTO schema_migrations (id) VALUES (%s)", (name,))

    cur.close()
    conn.close()
    print("Migrations complete")


if __name__ == "__main__":
    main()
