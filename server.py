import os
import json
import time
from datetime import date

import requests
from flask import Flask, jsonify, render_template, request, send_from_directory
from werkzeug.utils import secure_filename

app = Flask(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
VIDEOS_DIR = os.path.join(BASE_DIR, "videos")
ASSETS_DIR = os.path.join(BASE_DIR, "assets")
OVERLAYS_DIR = os.path.join(BASE_DIR, "overlays")
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
SPECIAL_DAYS_FILE = os.path.join(BASE_DIR, "special_days.json")

VIDEO_EXTENSIONS = {"mp4", "webm", "mov", "avi", "mkv"}
LOGO_EXTENSIONS = {"png", "jpg", "jpeg", "svg", "webp"}

_weather_cache = {"data": None, "fetched_at": 0}
WEATHER_TTL = 1800  # 30 minutes


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_config():
    with open(CONFIG_FILE) as f:
        return json.load(f)


def save_config(config):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)


def get_logo_filename():
    for ext in LOGO_EXTENSIONS:
        candidate = os.path.join(ASSETS_DIR, f"logo.{ext}")
        if os.path.exists(candidate):
            return f"logo.{ext}"
    return None


def fetch_weather(city, api_key):
    try:
        r = requests.get(
            "https://api.openweathermap.org/data/2.5/weather",
            params={"q": city, "appid": api_key, "units": "metric"},
            timeout=10,
        )
        r.raise_for_status()
        d = r.json()
        return {
            "city": d["name"],
            "temp": round(d["main"]["temp"], 1),
        }
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Display endpoints
# ---------------------------------------------------------------------------

@app.route("/")
def display():
    return render_template("display.html")


@app.route("/api/config")
def api_config():
    cfg = load_config()
    logo = get_logo_filename()
    return jsonify(
        {
            "orientation": cfg.get("orientation", "horizontal"),
            "logo_url": f"/assets/{logo}" if logo else None,
            "schedule_on":  cfg.get("schedule_on",  "07:00"),
            "schedule_off": cfg.get("schedule_off", "19:00"),
        }
    )


def get_ordered_videos():
    on_disk = {
        f for f in os.listdir(VIDEOS_DIR)
        if f.rsplit(".", 1)[-1].lower() in VIDEO_EXTENSIONS
    }
    cfg = load_config()
    order = cfg.get("video_order", [])
    result = [f for f in order if f in on_disk]
    result += sorted(f for f in on_disk if f not in result)
    return result


@app.route("/api/videos")
def api_videos():
    return jsonify(get_ordered_videos())


@app.route("/api/weather")
def api_weather():
    cfg = load_config()
    now = time.time()
    if now - _weather_cache["fetched_at"] > WEATHER_TTL or _weather_cache["data"] is None:
        data = fetch_weather(cfg.get("city", ""), cfg.get("weather_api_key", ""))
        if data:
            _weather_cache["data"] = data
            _weather_cache["fetched_at"] = now
    return jsonify(_weather_cache["data"] or {"city": cfg.get("city", ""), "temp": None})


@app.route("/api/special-day")
def api_special_day():
    try:
        with open(SPECIAL_DAYS_FILE) as f:
            days = json.load(f)
        today = date.today().strftime("%m-%d")
        for d in days:
            from_d = d.get("date_from") or d.get("date", "")
            to_d   = d.get("date_to")   or d.get("date", "")
            if from_d and to_d and from_d <= today <= to_d:
                entry = dict(d)
                if entry.get("image"):
                    entry["image_url"] = f"/overlays/{entry['image']}"
                return jsonify(entry)
    except Exception:
        pass
    return jsonify(None)


@app.route("/videos/<path:filename>")
def serve_video(filename):
    return send_from_directory(VIDEOS_DIR, filename)


@app.route("/assets/<path:filename>")
def serve_assets(filename):
    return send_from_directory(ASSETS_DIR, filename)


@app.route("/overlays/<path:filename>")
def serve_overlays(filename):
    return send_from_directory(OVERLAYS_DIR, filename)


# ---------------------------------------------------------------------------
# Admin endpoints
# ---------------------------------------------------------------------------

@app.route("/admin")
def admin():
    cfg = load_config()
    videos = get_ordered_videos()
    logo = get_logo_filename()
    return render_template(
        "admin.html", config=cfg, videos=videos, logo_url=f"/assets/{logo}" if logo else None
    )


@app.route("/admin/upload-video", methods=["POST"])
def upload_video():
    f = request.files.get("video")
    if not f or not f.filename:
        return jsonify({"error": "No file provided"}), 400
    ext = f.filename.rsplit(".", 1)[-1].lower() if "." in f.filename else ""
    if ext not in VIDEO_EXTENSIONS:
        return jsonify({"error": f"Unsupported format. Use: {', '.join(VIDEO_EXTENSIONS)}"}), 400
    filename = secure_filename(f.filename)
    f.save(os.path.join(VIDEOS_DIR, filename))
    return jsonify({"success": True, "filename": filename})


@app.route("/admin/upload-logo", methods=["POST"])
def upload_logo():
    f = request.files.get("logo")
    if not f or not f.filename:
        return jsonify({"error": "No file provided"}), 400
    ext = f.filename.rsplit(".", 1)[-1].lower() if "." in f.filename else ""
    if ext not in LOGO_EXTENSIONS:
        return jsonify({"error": f"Unsupported format. Use: {', '.join(LOGO_EXTENSIONS)}"}), 400
    # Remove any existing logo
    for old_ext in LOGO_EXTENSIONS:
        old = os.path.join(ASSETS_DIR, f"logo.{old_ext}")
        if os.path.exists(old):
            os.remove(old)
    f.save(os.path.join(ASSETS_DIR, f"logo.{ext}"))
    return jsonify({"success": True})


@app.route("/admin/reorder-videos", methods=["POST"])
def reorder_videos():
    data = request.get_json() or {}
    order = data.get("order", [])
    cfg = load_config()
    cfg["video_order"] = order
    save_config(cfg)
    return jsonify({"success": True})


@app.route("/admin/delete-video/<filename>", methods=["POST"])
def delete_video(filename):
    path = os.path.join(VIDEOS_DIR, secure_filename(filename))
    if os.path.exists(path):
        os.remove(path)
    return jsonify({"success": True})


@app.route("/admin/config", methods=["POST"])
def update_config():
    cfg = load_config()
    data = request.get_json() or {}
    for key in ("city", "weather_api_key", "orientation", "schedule_on", "schedule_off"):
        if key in data:
            cfg[key] = data[key]
    save_config(cfg)
    _weather_cache["fetched_at"] = 0  # invalidate cache
    return jsonify({"success": True})


# ---------------------------------------------------------------------------

if __name__ == "__main__":
    os.makedirs(VIDEOS_DIR, exist_ok=True)
    os.makedirs(ASSETS_DIR, exist_ok=True)
    os.makedirs(OVERLAYS_DIR, exist_ok=True)
    if not os.path.exists(CONFIG_FILE):
        save_config({
            "city": "Buenos Aires",
            "weather_api_key": "",
            "orientation": "horizontal",
            "schedule_on": "07:00",
            "schedule_off": "19:00",
        })
    app.run(host="0.0.0.0", port=8080, debug=False)
