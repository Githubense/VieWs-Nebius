"""
Unit tests for the VieWs Nebius Serverless Endpoints Proxy.
"""

from fastapi.testclient import TestClient
import main
from main import app, extract_json, sanitize_weather, sanitize_palette

client = TestClient(app)

def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    assert "status" in response.json()

def test_root():
    response = client.get("/")
    assert response.status_code == 200
    data = response.json()
    assert data["app"] == "VieWs Ambient Weather Inference Proxy"
    assert data["service"] == "Nebius Serverless Endpoints"

def test_extract_json():
    fenced = "```json\n{\"weather\": {\"sceneTitle\": \"Rain\"}}\n```"
    assert extract_json(fenced) == "{\"weather\": {\"sceneTitle\": \"Rain\"}}"

    thinking = "<think>user feels sad</think>\n{\"weather\": {\"sceneTitle\": \"Rain\"}}"
    assert extract_json(thinking) == "{\"weather\": {\"sceneTitle\": \"Rain\"}}"

def test_sanitize_weather_physics():
    # Rain and snow mutual exclusivity
    conflict = {
        "sceneTitle": "Rain Snow",
        "atmosphereDescription": "test",
        "precipitation": 0.6,
        "windSpeed": 0.2,
        "fogDensity": 0.0,
        "snowIntensity": 0.3,
        "clearness": 0.8,
        "lightningFrequency": 0.5,
        "colorTemperature": "warm"
    }
    s = sanitize_weather(conflict)
    assert s["snowIntensity"] == 0.0
    assert s["clearness"] <= 0.1
    # Rain with warm background shifts to cool
    assert s["colorTemperature"] == "cool"

def test_sanitize_palette():
    valid_palette = {
        "title": "Wet Stone",
        "colors": [
            {"name": "bg", "hex": "#112233"},
            {"name": "surface", "hex": "#223344"},
            {"name": "text", "hex": "#EEEEEE"},
            {"name": "accent", "hex": "#4488AA"},
            {"name": "secondary", "hex": "#6699BB"}
        ]
    }
    p = sanitize_palette(valid_palette)
    assert p is not None
    assert len(p["colors"]) == 5

    bad_palette = {"title": "broken", "colors": "not an array"}
    assert sanitize_palette(bad_palette) is None

def test_scene_fallback_when_no_key():
    # When no key is set, returns FALLBACK_CALM
    response = client.post("/v1/scene", json={"emotion": "peaceful contemplation"})
    assert response.status_code == 200
    data = response.json()
    assert data["weather"]["sceneTitle"] == "Calm Breeze"
