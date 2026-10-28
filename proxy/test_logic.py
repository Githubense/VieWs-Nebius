"""
Pure standard-library tests for proxy string extraction and sanitization logic.
Can run anywhere without installing external dependencies.
"""

import unittest
import re

ALLOWED_COLOR_TEMPERATURES = [
    "warm", "cool", "neutral", "melancholy", "golden",
    "crimson", "dusk", "arctic", "ember", "ash"
]

def extract_json(raw: str) -> str:
    text = re.sub(r"<think>[\s\S]*?</think>", "", raw)
    text = re.sub(r"<think>[\s\S]*$", "", text)
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and start < end:
        return text[start:end+1]
    return text.strip()

def sanitize_weather(w: dict) -> dict:
    def clamp(val, lo: float = 0.0, hi: float = 0.8) -> float:
        try:
            return max(lo, min(hi, float(val)))
        except (ValueError, TypeError):
            return lo

    precip = clamp(w.get("precipitation", 0.0))
    wind = max(0.0, min(1.0, float(w.get("windSpeed", 0.0))))
    fog = clamp(w.get("fogDensity", 0.0))
    snow = clamp(w.get("snowIntensity", 0.0))
    clearness = clamp(w.get("clearness", 0.0))
    lightning = clamp(w.get("lightningFrequency", 0.0))

    if precip > 0.0 and snow > 0.0:
        if precip >= snow:
            snow = 0.0
        else:
            precip = 0.0

    if precip > 0.2 or snow > 0.2 or fog > 0.3:
        clearness = min(clearness, 0.1)

    if precip < 0.3:
        lightning = 0.0

    temp = str(w.get("colorTemperature", "neutral")).lower()
    if temp not in ALLOWED_COLOR_TEMPERATURES:
        temp = "neutral"

    if snow > 0.2 and temp in ["warm", "golden", "neutral"]:
        temp = "cool"
    if precip > 0.4 and temp in ["warm", "golden", "arctic"]:
        temp = "cool"
    if temp == "golden" and clearness <= 0.4:
        temp = "warm"

    title = str(w.get("sceneTitle", "")).strip() or "Quiet Sky"
    desc = str(w.get("atmosphereDescription", "")).strip() or "The air settles softly around you."

    return {
        "sceneTitle": title,
        "atmosphereDescription": desc,
        "precipitation": precip,
        "windSpeed": wind,
        "fogDensity": fog,
        "snowIntensity": snow,
        "clearness": clearness,
        "lightningFrequency": lightning,
        "colorTemperature": temp
    }

class TestProxyLogic(unittest.TestCase):
    def test_extract_json(self):
        fenced = "```json\n{\"weather\": {\"sceneTitle\": \"Rain\"}}\n```"
        self.assertEqual(extract_json(fenced), "{\"weather\": {\"sceneTitle\": \"Rain\"}}")

        thinking = "<think>user feels sad</think>\n{\"weather\": {\"sceneTitle\": \"Rain\"}}"
        self.assertEqual(extract_json(thinking), "{\"weather\": {\"sceneTitle\": \"Rain\"}}")

    def test_sanitize_weather(self):
        conflict = {
            "sceneTitle": "Storm",
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
        self.assertEqual(s["snowIntensity"], 0.0)
        self.assertLessEqual(s["clearness"], 0.1)
        self.assertEqual(s["colorTemperature"], "cool")

if __name__ == "__main__":
    unittest.main()
