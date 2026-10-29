"""
Nebius Serverless Endpoints Proxy for VieWs Ambient Weather App.

Shields client devices from exposing the Token Factory API key while
serving generated atmospheric weather states and palettes powered by
NVIDIA Nemotron open models.
"""

import os
import re
import json
import time
from typing import List, Optional, Dict, Any
from collections import defaultdict

import httpx
from fastapi import FastAPI, HTTPException, Request, Header, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# ── Configuration ─────────────────────────────────────────────────────────────

NEBIUS_API_KEY = os.getenv("NEBIUS_API_KEY", "")
NEBIUS_MODEL = os.getenv("NEBIUS_MODEL", "nvidia/Nemotron-3_5-Lightning")
NEBIUS_BASE_URL = os.getenv("NEBIUS_BASE_URL", "https://api.tokenfactory.eu-north1.nebius.com/v1/").rstrip("/")
TAVILY_API_KEY = os.getenv("TAVILY_API_KEY", "")
APP_TOKEN = os.getenv("APP_TOKEN", "")  # Optional shared secret header
RATE_LIMIT_PER_MINUTE = int(os.getenv("RATE_LIMIT_PER_MINUTE", "40"))

ALLOWED_COLOR_TEMPERATURES = [
    "warm", "cool", "neutral", "melancholy", "golden",
    "crimson", "dusk", "arctic", "ember", "ash"
]

SYSTEM_PROMPT = """You are an environmental parameter generator for a procedural weather atmosphere app.
Given an emotion or feeling, output precise numeric values that create the matching atmosphere,
plus a matching 5-colour palette.

CRITICAL: Do NOT think out loud in the content. Output ONLY the JSON object, starting immediately with "{", exactly this shape:
{
  "weather": {
    "sceneTitle": "two evocative words",
    "atmosphereDescription": "one minimalist sentence, 10-15 words, no metaphors",
    "precipitation": 0.0, "windSpeed": 0.0, "fogDensity": 0.0,
    "snowIntensity": 0.0, "clearness": 0.0, "lightningFrequency": 0.0,
    "colorTemperature": "one of: warm, cool, neutral, melancholy, golden, crimson, dusk, arctic, ember, ash"
  },
  "palette": {
    "title": "short evocative palette title",
    "colors": [
      {"name": "background ...", "hex": "#RRGGBB"},
      {"name": "surface ...",    "hex": "#RRGGBB"},
      {"name": "text ...",       "hex": "#RRGGBB"},
      {"name": "accent ...",     "hex": "#RRGGBB"},
      {"name": "secondary ...",  "hex": "#RRGGBB"}
    ]
  }
}

STRICT WEATHER RULES — violating these will break the experience:
1. Rain (precipitation) and snow (snowIntensity) are mutually exclusive. Set exactly ONE to a non-zero value, never both.
2. clearness must be 0.0 whenever precipitation > 0.2, snowIntensity > 0.2, or fogDensity > 0.3.
3. lightningFrequency must be 0.0 unless precipitation >= 0.3.
4. colorTemperature MUST contrast with the active weather:
   - snowing        → 'cool', 'arctic', or 'dusk' (particles need a non-white background)
   - heavy rain     → 'cool', 'melancholy', or 'dusk'
   - storm/rage     → 'melancholy', 'crimson', or 'dusk'
   - sunny/warm clear → 'golden' or 'warm'
   - cold clear sky → 'arctic'
   - foggy/overcast → 'neutral', 'ash', or 'cool'
   - smoldering/ember → 'ember'
   - twilight/mystery → 'dusk'
   - passion/wound  → 'crimson'
   - Never use 'golden' unless clearness > 0.5
   - Never use 'warm', 'golden', 'neutral', or 'arctic' for heavy snow or storm
5. All numeric values are between 0.0 and 0.8. Use the range — do not cluster near 0.
6. Choose the dominant weather type and set all competing types to 0. Focused scenes are more immersive.

STRICT PALETTE RULES — you are a colour theorist for atmospheric, emotional UI palettes.
Return exactly 5 colours in this fixed order: [0] background (dominant sky/atmosphere tone),
[1] surface (subtle lighter or darker overlay of the background), [2] text (clearly readable on the
background: dark on light, light on dark), [3] accent (emotionally evocative highlight matching the
dominant weather), [4] secondary (softer accent or particle/mote tint).
Every colour must belong to exactly one family, chosen from colorTemperature and the weather:
• PASTEL — lightness 75–90, saturation 15–40. Soft, airy. For warm, golden, light clear scenes.
          Arctic scenes: lightness 75–92, saturation 4–18, cold blue-grey undertones.
• SOFT   — lightness 45–75, saturation 10–30. Muted, painterly. For neutral, cool, misty, foggy, light snow.
          Ash scenes: lightness 45–65, saturation 4–15.
• DARK   — lightness 8–40, saturation 10–35. Moody, deep, brooding. For melancholy, crimson, dusk, ember,
          storm, heavy rain, night scenes.
FORBIDDEN: vivid primaries, neon tones, saturation above 45, pure black (#000000), pure white (#ffffff).
Every hex is exactly 7 characters including the # prefix.
The palette must visibly reflect the active conditions."""

# ── Schemas ───────────────────────────────────────────────────────────────────

class SceneRequest(BaseModel):
    emotion: str = Field(..., min_length=1, max_length=300, description="User emotion or atmospheric query")
    history: Optional[List[str]] = Field(default=None, description="Recent emotion titles for mood continuity")

class WeatherState(BaseModel):
    sceneTitle: str
    atmosphereDescription: str
    precipitation: float
    windSpeed: float
    fogDensity: float
    snowIntensity: float
    clearness: float
    lightningFrequency: float
    colorTemperature: str

class GeneratedColor(BaseModel):
    name: str
    hex: str

class ColorPalette(BaseModel):
    title: str
    colors: List[GeneratedColor]

class SceneResponse(BaseModel):
    weather: WeatherState
    palette: Optional[ColorPalette] = None
    grounding: Optional[str] = None
    groundingLocation: Optional[str] = None

# ── Fallback Defaults ─────────────────────────────────────────────────────────

FALLBACK_CALM = SceneResponse(
    weather=WeatherState(
        sceneTitle="Calm Breeze",
        atmosphereDescription="A gentle wind moves through tall grass on a quiet afternoon.",
        precipitation=0.1,
        windSpeed=0.2,
        fogDensity=0.0,
        snowIntensity=0.0,
        clearness=0.6,
        lightningFrequency=0.0,
        colorTemperature="neutral"
    ),
    palette=None
)

FALLBACK_STORM = SceneResponse(
    weather=WeatherState(
        sceneTitle="Quiet Storm",
        atmosphereDescription="Heavy rain falls steadily, muffling the world into a grey stillness.",
        precipitation=0.7,
        windSpeed=0.4,
        fogDensity=0.2,
        snowIntensity=0.0,
        clearness=0.0,
        lightningFrequency=0.1,
        colorTemperature="melancholy"
    ),
    palette=None
)

# ── Rate Limiter ──────────────────────────────────────────────────────────────

request_history: Dict[str, List[float]] = defaultdict(list)

def is_rate_limited(ip: str) -> bool:
    now = time.time()
    cutoff = now - 60.0
    timestamps = [t for t in request_history[ip] if t > cutoff]
    request_history[ip] = timestamps
    if len(timestamps) >= RATE_LIMIT_PER_MINUTE:
        return True
    request_history[ip].append(now)
    return False

# ── Helpers ───────────────────────────────────────────────────────────────────

def extract_json(raw: str) -> str:
    """Strips <think> tags, markdown code blocks, and extraneous trailing/leading prose."""
    text = re.sub(r"<think>[\s\S]*?</think>", "", raw)
    text = re.sub(r"<think>[\s\S]*$", "", text)

    # 1. Look for ```json ... ``` code fence
    fenced = re.search(r"```(?:json)?\s*(\{[\s\S]*?\})\s*```", text)
    if fenced:
        cand = fenced.group(1).strip()
        try:
            json.loads(cand)
            return cand
        except Exception:
            pass

    # 2. Balanced bracket scan finding a valid JSON object with "weather"
    pos = 0
    while True:
        start = text.find("{", pos)
        if start == -1:
            break
        depth = 0
        in_string = False
        escape = False
        end = -1
        for i in range(start, len(text)):
            c = text[i]
            if escape:
                escape = False
                continue
            if c == "\\" and in_string:
                escape = True
                continue
            if c == '"':
                in_string = not in_string
                continue
            if not in_string:
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
        if end != -1:
            cand = text[start:end+1]
            if '"weather"' in cand:
                try:
                    json.loads(cand)
                    return cand
                except Exception:
                    pass
            pos = start + 1
        else:
            break

    # 3. Fallback
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and start < end:
        return text[start:end+1]
    return text.strip()

def sanitize_weather(w: Dict[str, Any]) -> Dict[str, Any]:
    """Applies strict atmospheric physics and contrast rules."""
    def clamp(val: Any, lo: float = 0.0, hi: float = 0.8) -> float:
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

    # Rule 1: Rain and snow mutual exclusivity
    if precip > 0.0 and snow > 0.0:
        if precip >= snow:
            snow = 0.0
        else:
            precip = 0.0

    # Rule 2: Clearness suppression
    if precip > 0.2 or snow > 0.2 or fog > 0.3:
        clearness = min(clearness, 0.1)

    # Rule 3: Lightning requires rain
    if precip < 0.3:
        lightning = 0.0

    # Color tone validation & contrast
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

def sanitize_palette(p: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not isinstance(p, dict):
        return None
    colors = p.get("colors")
    if not isinstance(colors, list) or len(colors) != 5:
        return None
    hex_pattern = re.compile(r"^#[0-9a-fA-F]{6}$")
    sanitized_colors = []
    for c in colors:
        if not isinstance(c, dict):
            return None
        name = str(c.get("name", "tone")).strip()
        h = str(c.get("hex", "")).strip()
        if not hex_pattern.match(h):
            return None
        sanitized_colors.append({"name": name, "hex": h.upper()})

    return {
        "title": str(p.get("title", "Atmospheric Palette")).strip(),
        "colors": sanitized_colors
    }

# ── FastAPI App ───────────────────────────────────────────────────────────────

app = FastAPI(
    title="VieWs Nebius Serverless Proxy",
    description="Secure inference proxy for Nebius Token Factory and NVIDIA Nemotron",
    version="1.1.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
def root():
    return {
        "app": "VieWs Ambient Weather Inference Proxy",
        "service": "Nebius Serverless Endpoints",
        "model": NEBIUS_MODEL,
        "configured": bool(NEBIUS_API_KEY),
        "status": "ready"
    }

@app.get("/health")
def health():
    return {"status": "ok", "time": time.time()}

ABSTRACT_WORDS = {
    # Internal feelings & mental states (English & Spanish)
    "love", "pain", "peace", "grief", "silence", "fear", "doubt", "darkness",
    "light", "hope", "despair", "chaos", "thought", "thoughts", "pieces", "shambles",
    "awe", "melancholy", "sad", "sadness", "happy", "happiness", "peaceful", "anxious",
    "anxiety", "exhausted", "exhaustion", "cozy", "nostalgic", "nostalgia",
    "dreamy", "serene", "lonely", "loneliness", "hopeful", "overwhelmed", "calm",
    "restless", "sleepy", "joy", "anger", "bored", "meditative", "quiet", "solitude",
    "stillness", "heartbroken", "tired", "stressed", "stress", "bliss", "gloomy",
    "depressed", "depression", "excited", "nervous", "empty", "emptiness", "lost",
    "daydreaming", "sorrow", "search", "head", "heart", "chest", "soul", "memory", "memories", "mood",
    "amor", "dolor", "paz", "soledad", "tristeza", "miedo", "rabia", "nostalgia", "calma",
    # Weather nouns (should not trigger city search)
    "rain", "snow", "thunder", "fog", "clouds", "sun", "wind", "storm", "drizzle", "sunshine",
    "lluvia", "nieve", "viento", "sol", "tormenta", "niebla",
    # Pronouns & grammatical objects
    "you", "me", "him", "her", "them", "us", "it", "this", "that", "all", "my",
    "your", "his", "their", "our", "a", "an", "the", "bed", "mind", "home", "work",
    "tears", "today", "yesterday", "tomorrow", "day", "night", "morning", "evening",
    "moment", "time", "life", "world", "here", "there", "school", "office", "room",
    "trabajo", "casa", "cama", "vida", "mundo", "aqui", "alli", "ti", "ella", "el"
}

WEATHER_ADJECTIVES = {
    "rainy", "sunny", "cloudy", "foggy", "snowy", "cold", "warm", "chilly", "windy",
    "stormy", "misty", "autumn", "winter", "summer", "spring", "gloomy", "breezy"
}

LOCATION_ABBREVS = {
    "ny": "New York", "nyc": "New York", "la": "Los Angeles", "sf": "San Francisco",
    "cdmx": "Mexico City", "dc": "Washington D.C."
}

PREP_WORDS = "in|at|from|to|near|around|visiting|miss|missing|of|over|through|for|en|hacia|desde|extraño|extrano|extrañando|visitando|por"
PREP_PAT = r"\b(?:" + PREP_WORDS + r")\s+((?:(?!\b(?:" + PREP_WORDS + r")\b)[A-Za-z])+(?:\s+(?:(?!\b(?:" + PREP_WORDS + r")\b)[A-Za-z])+){0,2})"

def detect_location(text: str) -> Optional[str]:
    """Universal grammatical-semantic check to extract a location name if referenced, or None if purely an emotion."""
    clean = text.replace("Emotion: ", "").strip()
    if not clean:
        return None
    lower = clean.lower()

    # 1. Abbreviations
    for abbr, full in LOCATION_ABBREVS.items():
        if re.search(r"\b" + re.escape(abbr) + r"\b", lower):
            return full

    # 2. Universal Spatial Prepositions in English & Spanish
    for m in re.finditer(PREP_PAT, clean, re.IGNORECASE):
        candidate = m.group(1).strip()
        words = candidate.split()
        if not words:
            continue
        first = words[0].lower()
        if first in ABSTRACT_WORDS or len(first) <= 2:
            continue

        # Check if 3-word place (e.g. Rio de Janeiro, Cabo San Lucas)
        if len(words) >= 3 and words[1].lower() in {"de", "del", "da", "san", "la", "los", "las", "el", "st", "saint"}:
            if words[2].lower() not in ABSTRACT_WORDS:
                particle = words[1].title() if words[1].lower() in {"san", "st", "saint"} else words[1].lower()
                return f"{words[0].title()} {particle} {words[2].title()}"

        # Check if 2-word place (e.g. New York, San Cristobal, Puerto Escondido)
        if len(words) >= 2 and words[1].lower() not in ABSTRACT_WORDS:
            return f"{words[0].title()} {words[1].title()}"

        return words[0].title()

    # 3. Weather Adjective + Destination (e.g. "rainy Paris" -> "Paris", "sunny Barcelona" -> "Barcelona")
    words = re.findall(r"[A-Za-z]+", clean)
    if len(words) == 2:
        w0, w1 = words[0].lower(), words[1].lower()
        if w0 in WEATHER_ADJECTIVES and w1 not in ABSTRACT_WORDS and len(w1) > 2:
            return words[1].title()

    # 4. Standalone query (1 to 2 words): if neither word is an abstract emotion, it is a destination
    if 1 <= len(words) <= 2:
        if all(w.lower() not in ABSTRACT_WORDS and len(w) > 2 for w in words):
            return " ".join(w.title() for w in words)

    return None

async def fetch_tavily_grounding(location: str) -> Optional[str]:
    """Retrieves real-world atmospheric grounding from Tavily AI search for a specific location."""
    if not TAVILY_API_KEY or TAVILY_API_KEY.startswith("YOUR_"):
        return None
    try:
        query = f"current weather in {location} today conditions temperature sky"
        payload = {
            "api_key": TAVILY_API_KEY,
            "query": query,
            "search_depth": "basic",
            "include_answer": True,
            "max_results": 5
        }
        async with httpx.AsyncClient(timeout=4.0) as client:
            resp = await client.post("https://api.tavily.com/search", json=payload)
            if resp.status_code == 200:
                data = resp.json()
                answer = data.get("answer")
                if answer and "do not provide" not in str(answer).lower() and "could not find" not in str(answer).lower():
                    return str(answer).strip()
                results = data.get("results", [])
                for r in results:
                    c = r.get("content", "")
                    if "°" in c:
                        return str(c).strip()[:240]
    except Exception as exc:
        print(f"Tavily search notice: {exc}")
    return None

@app.post("/v1/scene", response_model=SceneResponse)
@app.post("/scene", response_model=SceneResponse)
async def generate_scene(
    req: SceneRequest,
    request: Request,
    x_app_token: Optional[str] = Header(None)
):
    client_ip = request.client.host if request.client else "unknown"
    if is_rate_limited(client_ip):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Rate limit exceeded. Please wait a moment."
        )

    if APP_TOKEN and x_app_token != APP_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Unauthorized application token."
        )

    # Return clean fallback if API key is not configured on the server
    if not NEBIUS_API_KEY or NEBIUS_API_KEY.startswith("YOUR_"):
        return FALLBACK_CALM

    # 1. Detect location and fetch real-world grounding via Tavily AI Search (only if location referenced)
    detected_location = detect_location(req.emotion)
    grounding = None
    if detected_location:
        grounding = await fetch_tavily_grounding(detected_location)

    user_prompt = f"Emotion: {req.emotion.strip()}"
    if grounding and detected_location:
        user_prompt += f"\nReal-world atmospheric grounding for {detected_location} (via Tavily search): {grounding}\nBlend this real-world sensory context with the emotion."
    elif grounding:
        user_prompt += f"\nReal-world atmospheric grounding (via Tavily search): {grounding}\nBlend this real-world sensory context with the emotion."
    if req.history:
        recent = ", ".join(req.history[-3:])
        user_prompt += f"\nRecent emotional atmosphere context: {recent}"

    headers = {
        "Authorization": f"Bearer {NEBIUS_API_KEY}",
        "Content-Type": "application/json"
    }

    payload = {
        "model": NEBIUS_MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt}
        ],
        "temperature": 0.4,
        "max_tokens": 3000,
        "response_format": {"type": "json_object"}
    }

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{NEBIUS_BASE_URL}/chat/completions",
                headers=headers,
                json=payload
            )

        if resp.status_code != 200:
            print(f"Nebius Token Factory returned HTTP {resp.status_code}: {resp.text[:200]}")
            return FALLBACK_STORM

        data = resp.json()
        msg = data["choices"][0]["message"]
        content = msg.get("content") or msg.get("reasoning") or msg.get("reasoning_content") or ""
        extracted = extract_json(content)
        parsed = json.loads(extracted)

        raw_weather = parsed.get("weather", {})
        clean_weather = sanitize_weather(raw_weather)
        clean_palette = sanitize_palette(parsed.get("palette"))

        return SceneResponse(
            weather=WeatherState(**clean_weather),
            palette=ColorPalette(**clean_palette) if clean_palette else None,
            grounding=grounding,
            groundingLocation=detected_location
        )

    except Exception as exc:
        print(f"Inference error: {exc}")
        return FALLBACK_STORM
