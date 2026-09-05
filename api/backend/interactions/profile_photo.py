"""Presigned-S3 profile-photo upload for user accounts.

Sibling to ``backend/interactions/attachments.py`` (task
20260904-messaging-attachments) -- reuses that module's S3 client,
bucket/region config, "image" MIME/size allowlist, and presigned-POST/GET
machinery wholesale rather than duplicating any of it, since a profile
photo is just another image upload into the same bucket under its own
purpose-specific key prefix. See ``attachments.py``'s own module docstring
for the full threat-model rationale (presigned POST not PUT so
size/content-type are cryptographically bound, server-derived object keys,
fail-closed on an unrecognized MIME) -- identical reasoning applies here
and is not repeated.

Threat-model decisions specific to profile photos (task
20260905-profile-photo, security gate step 6):
    - Only the "image" kind is ever valid here -- video/file/gif never
      apply to a profile photo, so this module doesn't expose
      ``attachment_kind`` as a caller-supplied parameter at all, closing
      off a class of confusion ``attachments.py``'s generic entry point
      otherwise has to guard against via its allowlist check.
    - Object keys live under their own prefix
      (``profile-photos/{user_id}/{uuid4()}{ext}``), distinct from
      ``attachments/...`` -- a profile-photo object can never be confused
      with, or swept alongside, a message attachment despite sharing one
      bucket.
    - ``is_own_profile_photo_key`` is a defense-in-depth check
      ``routes/profile_photo.py``'s confirm endpoint applies before ever
      persisting a client-submitted object_key -- fails closed (False) for
      anything that doesn't unambiguously fall under the *caller's own*
      prefix, including any key containing a ``..`` traversal-looking
      segment (Security Posture Q7/Q14: never trust the upload-url step
      alone to guarantee what gets confirmed later).
    - No new size/MIME/TTL tunables are introduced here -- profile photos
      reuse ``attachments.py``'s existing "image" ``PER_KIND_LIMITS`` entry
      and its ``UPLOAD_URL_TTL_SECONDS``/``DOWNLOAD_URL_TTL_SECONDS``
      constants verbatim (Configuration Philosophy Q1/Q2: a real,
      documented reason to diverge would justify a separate tunable: none
      exists today).
    - Object deletion (replace/remove/account-deletion cleanup) reuses
      ``attachments.delete_object`` directly -- fail-soft, logged not
      raised, so a failed cleanup of the *old* object never blocks the
      user-facing replace/remove/account-deletion action.
"""

from backend.interactions.attachments import generate_upload_policy

# Distinct from ATTACHMENT_KEY_PREFIX ("attachments") -- see module
# docstring. Profile-photo objects live at
# f"{PROFILE_PHOTO_KEY_PREFIX}/{user_id}/{uuid4()}{ext}".
PROFILE_PHOTO_KEY_PREFIX = "profile-photos"


def generate_profile_photo_upload_policy(user_id: str, content_type: str) -> dict:
    """Issue a presigned S3 POST policy for the caller's own profile-photo upload.

    Thin, "image"-only wrapper over ``attachments.generate_upload_policy``
    (same validation, same presigned-POST construction) -- see that
    function's docstring for the full behavior/error contract, including
    fail-closed ``ValueError`` on an unsupported ``content_type`` and
    ``AttachmentConfigError`` if S3 isn't configured.

    Args:
        user_id: The *authenticated* caller's own user_id (never
            client-supplied path data) -- becomes part of the object key.
        content_type: The MIME type the client intends to upload; must be
            one of ``attachments.PER_KIND_LIMITS["image"]["allowed_mime"]``.

    Returns:
        dict: ``{"url", "fields", "object_key", "expires_in"}`` -- see
            ``attachments.generate_upload_policy``.
    """
    return generate_upload_policy(
        user_id, "image", content_type, key_prefix=PROFILE_PHOTO_KEY_PREFIX
    )


def is_own_profile_photo_key(user_id: str, object_key: str | None) -> bool:
    """True iff ``object_key`` unambiguously falls under this user's own
    profile-photo prefix.

    Defense-in-depth check applied at *confirm* time (not just trusted from
    the upload-url step) before ever persisting a client-submitted key onto
    the user's row -- fails closed (``False``) for a blank key, a key under
    a different user's prefix, or anything with a ``..`` traversal-looking
    segment.
    """
    if not object_key or ".." in object_key:
        return False
    return object_key.startswith(f"{PROFILE_PHOTO_KEY_PREFIX}/{user_id}/")
