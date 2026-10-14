from pydantic import BaseModel, ConfigDict, Field


class TranscriptSegment(BaseModel):
    """One final transcript segment. Text only; per-segment length is enforced
    against config (ingest_max_segment_chars) in the route, not a constant here."""
    model_config = ConfigDict(extra="forbid")
    speaker_id: str | None = Field(default=None, max_length=64)  # the speaker's FellowScript user id
    text: str


class TranscriptIngestRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    segments: list[TranscriptSegment]
