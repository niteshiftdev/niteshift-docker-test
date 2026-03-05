import os
import json
import time

from flask import Flask, jsonify, request
import redis
import MySQLdb

app = Flask(__name__)

redis_client = redis.from_url(os.environ["REDIS_URL"])

def get_db():
    return MySQLdb.connect(
        host=os.environ["MYSQL_HOST"],
        user=os.environ["MYSQL_USER"],
        passwd=os.environ["MYSQL_PASSWORD"],
        db=os.environ["MYSQL_DATABASE"],
    )


@app.route("/health")
def health():
    return jsonify(status="ok", service="api")


@app.route("/items", methods=["GET"])
def list_items():
    """List items, with Redis caching."""
    cached = redis_client.get("items:all")
    if cached:
        return jsonify(items=json.loads(cached), source="cache")

    db = get_db()
    cur = db.cursor()
    cur.execute("SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT 50")
    rows = cur.fetchall()
    cur.close()
    db.close()

    items = [{"id": r[0], "name": r[1], "created_at": str(r[2])} for r in rows]
    redis_client.setex("items:all", 30, json.dumps(items))
    return jsonify(items=items, source="db")


@app.route("/items", methods=["POST"])
def create_item():
    """Create an item and enqueue a background job via Redis."""
    name = request.json.get("name", f"item-{int(time.time())}")

    db = get_db()
    cur = db.cursor()
    cur.execute("INSERT INTO items (name) VALUES (%s)", (name,))
    db.commit()
    item_id = cur.lastrowid
    cur.close()
    db.close()

    # Invalidate cache and enqueue a processing job for the worker
    redis_client.delete("items:all")
    redis_client.lpush("jobs:process", json.dumps({"item_id": item_id, "name": name}))

    return jsonify(id=item_id, name=name, queued=True), 201


@app.route("/stats")
def stats():
    """Aggregate stats from Redis and MySQL."""
    db = get_db()
    cur = db.cursor()
    cur.execute("SELECT COUNT(*) FROM items")
    total = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM items WHERE processed = TRUE")
    processed = cur.fetchone()[0]
    cur.close()
    db.close()

    queue_len = redis_client.llen("jobs:process")

    return jsonify(
        total_items=total,
        processed_items=processed,
        pending_jobs=queue_len,
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
