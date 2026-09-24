"""
CAMEL ModelFactory wrapper.
Supports env var overrides: MODEL_PLATFORM, MODEL_API_KEY, MODEL_API_URL,
MODEL_TIMEOUT, MODEL_MAX_RETRIES.
"""
import os
from camel.models import ModelFactory
from camel.types import ModelPlatformType
from configs.global_configs import global_configs

# Fail-fast defaults: one hung OpenRouter call must not burn retries × timeout
# against the whole AGENT_STEP_TIMEOUT budget (see smoke fetch-sf hang analysis).
DEFAULT_MODEL_TIMEOUT_S = 180.0
DEFAULT_MODEL_MAX_RETRIES = 0

# provider name → (ModelPlatformType, api_key_fn, default_base_url)
_PROVIDER_MAP = {
    "aihubmix":   (ModelPlatformType.OPENAI_COMPATIBLE_MODEL,
                   lambda: global_configs.aihubmix_key,
                   "https://aihubmix.com/v1"),
    "openai":     (ModelPlatformType.OPENAI,
                   lambda: global_configs.openai_official_key, None),
    "anthropic":  (ModelPlatformType.ANTHROPIC,
                   lambda: global_configs.anthropic_official_key, None),
    "deepseek":   (ModelPlatformType.DEEPSEEK,
                   lambda: global_configs.deepseek_official_key, None),
    "openrouter": (ModelPlatformType.OPENROUTER,
                   lambda: global_configs.openrouter_key, None),
    "qwen":       (ModelPlatformType.QWEN,
                   lambda: global_configs.qwen_official_key, None),
    "gemini":     (ModelPlatformType.GEMINI,
                   lambda: global_configs.google_official_key, None),
    "openai_compatible": (ModelPlatformType.OPENAI_COMPATIBLE_MODEL,
                          lambda: os.environ.get("MODEL_API_KEY", ""), None),
}


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or not str(raw).strip():
        return default
    value = float(str(raw).strip())
    if value <= 0:
        raise ValueError(f"{name} must be > 0, got {value!r}")
    return value


def _env_non_negative_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not str(raw).strip():
        return default
    value = int(str(raw).strip(), 10)
    if value < 0:
        raise ValueError(f"{name} must be >= 0, got {value!r}")
    return value


def build_model(model_name: str, provider: str):
    """Build a CAMEL BaseModelBackend.

    Env var overrides (take priority over provider map):
      MODEL_PLATFORM     - CAMEL ModelPlatformType name or provider key
      MODEL_API_KEY      - API key
      MODEL_API_URL      - base URL for compatible endpoints
      MODEL_TIMEOUT      - per-request HTTP timeout seconds (default 180)
      MODEL_MAX_RETRIES  - OpenAI SDK retries on timeout/transport errors (default 0)
    """
    # Env var overrides
    env_platform = os.environ.get("MODEL_PLATFORM")
    env_key      = os.environ.get("MODEL_API_KEY")
    env_url      = os.environ.get("MODEL_API_URL")
    timeout = _env_float("MODEL_TIMEOUT", DEFAULT_MODEL_TIMEOUT_S)
    max_retries = _env_non_negative_int("MODEL_MAX_RETRIES", DEFAULT_MODEL_MAX_RETRIES)

    if env_platform:
        # Try to resolve as provider key first, then as ModelPlatformType name
        if env_platform.lower() in _PROVIDER_MAP:
            platform, key_fn, default_url = _PROVIDER_MAP[env_platform.lower()]
        else:
            platform = ModelPlatformType[env_platform.upper()]
            key_fn = lambda: ""
            default_url = None
        api_key = env_key or key_fn()
        url = env_url or default_url
    else:
        if provider not in _PROVIDER_MAP:
            raise ValueError(
                f"Unknown provider '{provider}'. "
                f"Supported: {list(_PROVIDER_MAP.keys())}"
            )
        platform, key_fn, default_url = _PROVIDER_MAP[provider]
        api_key = env_key or key_fn()
        url = env_url or default_url

    kwargs = dict(
        model_platform=platform,
        model_type=model_name,
        api_key=api_key,
        timeout=timeout,
        max_retries=max_retries,
    )
    if url:
        # Anthropic SDK uses base_url without /v1 suffix; others need /v1
        if platform == ModelPlatformType.ANTHROPIC:
            kwargs["url"] = url.rstrip("/").rstrip("/v1")
        else:
            kwargs["url"] = url.rstrip("/") + ("/v1" if not url.rstrip("/").endswith("/v1") else "")

    return ModelFactory.create(**kwargs)
