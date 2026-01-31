import json
import math
from datetime import datetime, timezone
import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

# ISS Orbital Constants
EARTH_RADIUS_KM = 6371.0
ISS_ALTITUDE_KM = 408.0
ISS_ORBITAL_PERIOD_MIN = 92.65
ISS_INCLINATION_DEG = 51.6
ISS_VELOCITY_KMS = 7.66
REFERENCE_EPOCH = datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)
REFERENCE_LONGITUDE = -80.0

def get_cardinal(h):
    return ["N","NE","E","SE","S","SW","W","NW"][round(h/45)%8]

def calc_position():
    now = datetime.now(timezone.utc)
    mins = (now - REFERENCE_EPOCH).total_seconds() / 60.0
    phase = (mins / ISS_ORBITAL_PERIOD_MIN % 1.0) * 2 * math.pi
    inc = math.radians(ISS_INCLINATION_DEG)
    lat = math.degrees(math.asin(math.sin(inc) * math.sin(phase)))
    drift = (360/ISS_ORBITAL_PERIOD_MIN - 360/1436) * mins
    lon_off = math.degrees(math.atan2(math.cos(inc)*math.sin(phase), math.cos(phase)))
    lon = (REFERENCE_LONGITUDE - drift + lon_off) % 360
    if lon > 180: lon -= 360
    return lat, lon, now, phase

# Tool 1: Get ISS Position
@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="get_iss_position",
    description="Get the current position of the International Space Station",
    toolProperties="[]"
)
def get_iss_position(context) -> str:
    lat, lon, now, _ = calc_position()
    return json.dumps({
        "latitude": round(lat, 4),
        "longitude": round(lon, 4),
        "altitude_km": ISS_ALTITUDE_KM,
        "timestamp": now.isoformat()
    })

# Tool 2: Get ISS Velocity
@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="get_iss_velocity",
    description="Get the current velocity and heading of the ISS",
    toolProperties="[]"
)
def get_iss_velocity(context) -> str:
    lat, _, _, phase = calc_position()
    lat_r, inc_r = math.radians(lat), math.radians(ISS_INCLINATION_DEG)
    if abs(lat) < ISS_INCLINATION_DEG:
        heading = math.degrees(math.acos(max(-1, min(1, math.cos(lat_r)/math.cos(inc_r)))))
        if math.pi/2 < phase < 3*math.pi/2: heading = 180 - heading
    else:
        heading = 90 if lat > 0 else 270
    return json.dumps({
        "velocity_kms": ISS_VELOCITY_KMS,
        "velocity_mph": round(ISS_VELOCITY_KMS * 2236.94),
        "heading_degrees": round(heading, 1),
        "direction": get_cardinal(heading)
    })

# Tool 3: Get Orbital Info
@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="get_orbital_info",
    description="Get ISS orbital parameters",
    toolProperties="[]"
)
def get_orbital_info(context) -> str:
    return json.dumps({
        "altitude_km": ISS_ALTITUDE_KM,
        "orbital_period_minutes": ISS_ORBITAL_PERIOD_MIN,
        "inclination_degrees": ISS_INCLINATION_DEG,
        "velocity_kms": ISS_VELOCITY_KMS,
        "orbits_per_day": round(1440 / ISS_ORBITAL_PERIOD_MIN, 2)
    })

# Tool 4: Check Visibility
visibility_props = json.dumps([
    {"propertyName": "latitude", "propertyType": "number", "description": "Observer latitude"},
    {"propertyName": "longitude", "propertyType": "number", "description": "Observer longitude"}
])

@app.generic_trigger(
    arg_name="context",
    type="mcpToolTrigger",
    toolName="get_iss_visibility",
    description="Check if the ISS is visible from a given location",
    toolProperties=visibility_props
)
def get_iss_visibility(context) -> str:
    args = json.loads(context).get("arguments", {})
    obs_lat = args.get("latitude", 0)
    obs_lon = args.get("longitude", 0)

    iss_lat, iss_lon, _, _ = calc_position()
    lat1, lat2 = math.radians(obs_lat), math.radians(iss_lat)
    dlon = math.radians(iss_lon - obs_lon)
    cos_d = max(-1, min(1, math.sin(lat1)*math.sin(lat2) + math.cos(lat1)*math.cos(lat2)*math.cos(dlon)))
    dist = math.acos(cos_d) * EARTH_RADIUS_KM
    bearing = (math.degrees(math.atan2(
        math.sin(dlon)*math.cos(lat2),
        math.cos(lat1)*math.sin(lat2) - math.sin(lat1)*math.cos(lat2)*math.cos(dlon)
    )) + 360) % 360

    return json.dumps({
        "is_visible": dist < 2500,
        "distance_km": round(dist, 1),
        "direction": get_cardinal(bearing),
        "iss_latitude": round(iss_lat, 4),
        "iss_longitude": round(iss_lon, 4)
    })
