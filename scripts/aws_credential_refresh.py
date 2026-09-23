"""Re-read the AWS credentials file when AWS rejects the credentials in use.

The shim behind ``credential_process`` re-reads ``~/.env.aws`` on a schedule (see
``scripts/aws-creds-shim.sh``). That alone means a person can refresh the file and
still wait out the interval. A credential rejection from AWS is the strongest signal
available that re-reading is worth doing now, so this callback turns one into a
cache invalidation: the next request re-reads the file instead of waiting out the
interval.

botocore will not do this by itself: ``ExpiredTokenException`` comes back from the
Bedrock call long after credentials were resolved, and botocore neither invalidates
them nor retries. litellm's post-call failure hook is the insertion point.

The mechanism is indirect but short: litellm caches the ambient credentials object on
a process-wide cache, so dropping that entry makes the next request build a fresh
``boto3.Session``, which resolves credentials from scratch, which runs the shim,
which reads the file.
"""

from __future__ import annotations

import math
import os
import time
from typing import Any, Optional

from litellm.integrations.custom_logger import CustomLogger

try:  # pragma: no cover - logger location is litellm's, and the tag moves
    from litellm._logging import verbose_proxy_logger as _log
except Exception:  # pragma: no cover
    import logging

    _log = logging.getLogger(__name__)


def _positive_int_env(name: str, default: int) -> int:
    """Read an integer env var, falling back to the default on anything unusable.

    Deliberately lenient, unlike the shim's strict validation: a bad value here must
    not stop the proxy serving traffic. The effective value is logged so a typo is
    visible rather than silently in force.
    """
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        _log.warning("aws_credential_refresh: %s is not an integer (%r), using %ss", name, raw, default)
        return default
    if value < 1:
        _log.warning("aws_credential_refresh: %s must be >= 1 (got %s), using %ss", name, value, default)
        return default
    return value


# Minimum seconds between error-triggered cache-drop attempts, per worker process.
# A successful drop makes the next request re-read the file; a failed one re-reads
# nothing and leaves the schedule in charge.
#
# This bound is load-bearing, not a nicety. During an expired window *every* request
# fails, so without it this hook would invalidate on every failure and re-read the
# file once per request -- exactly the churn the scheduled re-read exists to avoid.
# A burst of failures inside one cooldown produces one drop attempt.
ERROR_REREAD_COOLDOWN = _positive_int_env("LITELLM_CREDS_ERROR_REREAD_COOLDOWN", 60)

# AWS error codes that mean "the credentials I sent were rejected", i.e. re-reading
# the file might help.
#
# AccessDeniedException is deliberately absent. It means the credentials were
# accepted and the *permission* was missing, which re-reading a file cannot fix --
# treating it as a refresh signal would re-read forever on every denied request.
CREDENTIAL_REJECTION_CODES = (
    "ExpiredToken",  # also matches ExpiredTokenException
    "InvalidClientTokenId",
    "UnrecognizedClientException",
)

# Message text for the same condition, in case a wrapper drops the error code.
CREDENTIAL_REJECTION_MESSAGES = (
    "security token included in the request is expired",
    "security token included in the request is invalid",
)


def _looks_like_credential_rejection(exception: BaseException) -> bool:
    # Substring match over the whole text, deliberately broad. A false positive costs
    # one extra shim run, capped by the cooldown. A false negative leaves pickup to the
    # scheduled re-read. The HTTP status is not checked either: the expired case
    # cannot be reproduced with fabricated credentials, so which status litellm
    # attaches to it is unmeasured.
    text = str(exception)
    if any(code in text for code in CREDENTIAL_REJECTION_CODES):
        return True
    lowered = text.lower()
    return any(message in lowered for message in CREDENTIAL_REJECTION_MESSAGES)


def _flush_aws_credential_cache() -> Optional[str]:
    """Drop litellm's cached AWS credentials. Returns None on success, else a reason.

    Everything here is private litellm surface reached through ``getattr``, because
    the image tracks ``main-latest``: a rename must produce a logged reason rather
    than an exception swallowed by the caller.
    """
    try:
        from litellm.llms.bedrock.base_aws_llm import BaseAWSLLM
    except Exception as exc:
        return f"cannot import BaseAWSLLM ({type(exc).__name__})"

    cache = getattr(BaseAWSLLM, "_shared_iam_cache", None)
    if cache is None:
        return "BaseAWSLLM._shared_iam_cache is missing (litellm internals changed)"

    flush = getattr(cache, "flush_cache", None)
    if not callable(flush):
        return "BaseAWSLLM._shared_iam_cache has no flush_cache() (litellm internals changed)"

    # Process-wide flush rather than a targeted delete: the precise key comes from
    # get_cache_key(credential_args), which this hook does not reliably have. The cost
    # of over-flushing is at most one extra shim invocation per AWS deployment.
    flush()
    return None


class AwsCredentialRefresh(CustomLogger):
    """Invalidate cached AWS credentials when AWS rejects them."""

    def __init__(self) -> None:
        super().__init__()
        # Monotonic, so a host clock adjustment cannot disable the cooldown or wedge
        # it shut. None means "never fired".
        self._last_flush_monotonic: Optional[float] = None

    def _cooldown_remaining(self, now: float) -> float:
        if self._last_flush_monotonic is None:
            return 0.0
        elapsed = now - self._last_flush_monotonic
        return max(0.0, ERROR_REREAD_COOLDOWN - elapsed)

    async def async_post_call_failure_hook(
        self,
        request_data: dict,
        original_exception: Exception,
        user_api_key_dict: Any,
        traceback_str: Optional[str] = None,
    ) -> None:
        """Never raises, and never returns an HTTPException.

        litellm catches and logs exceptions from this hook and carries on, so a
        failure in here is invisible from outside -- hence the broad guard, and a
        logged reason on every path that declines to act for a reason an operator
        would want to know.

        Only the warning and error paths below are visible by default: measured in the
        image, verbose_proxy_logger sits at NOTSET and inherits root's WARNING, and
        LITELLM_LOG moves the *handler* level only, so it cannot lower this on its own.
        The cooldown and not-a-rejection messages need `litellm --detailed_debug`. The
        path that matters for silent failure -- litellm internals renamed, so nothing
        was invalidated -- logs at error and is always visible.

        Returning None leaves the client's error response exactly as it was: this hook
        changes what happens to the *next* request, not this one.
        """
        try:
            if not _looks_like_credential_rejection(original_exception):
                # Debug only: this is the common case for every ordinary failure. It is
                # the line to look for if AWS changes how it reports a rejection and
                # the matcher stops recognising it. Type name only -- the message can
                # carry request content.
                _log.debug(
                    "aws_credential_refresh: %s is not a credential rejection; no re-read",
                    type(original_exception).__name__,
                )
                return None

            now = time.monotonic()
            remaining = self._cooldown_remaining(now)
            if remaining > 0:
                _log.info(
                    "aws_credential_refresh: credential rejection seen, but a cache drop was "
                    "already attempted %ds ago; next attempt allowed in %ds",
                    # Floor and ceiling, so a declined call never reports 0s remaining.
                    math.floor(ERROR_REREAD_COOLDOWN - remaining),
                    math.ceil(remaining),
                )
                return None

            # Claim the cooldown before flushing, so concurrent failures cannot each
            # decide they are first. Claimed even if the flush then fails, so a renamed
            # litellm internal logs its error once per cooldown, not once per request. Safe without a lock: there is no await between
            # the check above and this assignment, so it is atomic with respect to the
            # event loop. Under multiple worker processes the bound is per worker.
            self._last_flush_monotonic = now

            reason = _flush_aws_credential_cache()
            if reason is not None:
                _log.error(
                    "aws_credential_refresh: cannot invalidate cached AWS credentials (%s). "
                    "Falling back to the scheduled re-read; pickup may take up to the "
                    "configured interval.",
                    reason,
                )
                return None

            _log.warning(
                "aws_credential_refresh: AWS rejected the credentials in use; dropped the "
                "cached credentials so the next request re-reads the credentials file."
            )
        except Exception as exc:  # pragma: no cover - must never break the error path
            # Type name only, and no traceback: the message of an arbitrary exception
            # raised in here can carry request content.
            _log.error("aws_credential_refresh: hook failed, ignoring: %s", type(exc).__name__)
        return None


# litellm_config.yaml references this instance by
# "aws_credential_refresh.aws_credential_refresh_instance".
aws_credential_refresh_instance = AwsCredentialRefresh()
