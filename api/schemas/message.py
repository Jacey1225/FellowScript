from pydantic import BaseModel, Field

# Recognized attachment kinds a message may carry (task
# 20260904-messaging-attachments). Kept as a plain enum-like set rather than
# a schema-level Literal so ConnectionManager.send_msg's fail-closed check
# (an unrecognized kind is dropped, never coerced) can validate against the
# same source of truth a route/schema failure would otherwise hide behind a
# generic 422.
ATTACHMENT_KINDS = frozenset({"image", "video", "file", "gif"})


class Message(BaseModel):
    from_user: str
    timestamp: str
    to_users: list[str]
    group_id: str | None
    # Defaults to "" (not required) so an attachment-only message doesn't
    # need to supply text at all -- check_clean already no-ops on blank text.
    text: str = ""
    # Nullable, coexisting with `text` -- unset for an ordinary text-only
    # message. `attachment_key` is the S3 *object key* (never a URL) for
    # image/video/file kinds; always None for "gif" (GIF bytes never touch
    # our storage -- only the provider's id/url, carried in `attachment_meta`,
    # is ever stored). See backend/interactions/attachments.py.
    attachment_kind: str | None = None
    attachment_key: str | None = None
    attachment_meta: dict = Field(default_factory=dict)


class Group(BaseModel):
    group_id: str
    title: str
    users: list[str]


class UploadUrlRequest(BaseModel):
    """POST /message/upload-url/{user_id} request body.

    `size_bytes` is advisory only, used solely to pick which per-kind limit
    applies when composing the request -- real enforcement is the presigned
    POST policy's content-length-range condition (S3-enforced), not this
    client-declared value.
    """
    attachment_kind: str
    content_type: str
    size_bytes: int | None = None


class GifSearchResult(BaseModel):
    id: str
    url: str
    preview_url: str
    width: int
    height: int
