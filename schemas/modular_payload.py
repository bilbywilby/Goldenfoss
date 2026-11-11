"""Modular payload base schema with strict Pydantic v2 boundary controls."""
import re
from datetime import datetime, timezone
from typing import Any, Dict
from uuid import UUID, uuid4
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class Header(BaseModel):
    model_config = ConfigDict(extra="forbid")
    
    entity_id: UUID = Field(default_factory=uuid4)
    schema_version: str = "1.0.0"
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class ModularPayloadBase(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        validate_assignment=True,
        strict=True,
    )

    module_name: str
    payload: Dict[str, Any] = Field(default_factory=dict)
    is_active: bool = True
    header: Header = Field(default_factory=Header)

    @field_validator("module_name", mode="before")
    @classmethod
    def strip_and_validate_name(cls, v: Any) -> str:
        if not isinstance(v, str):
            raise ValueError("module_name must be a string")
        v_stripped = v.strip()
        if not re.match(r"^[a-z][a-z0-9_]*$", v_stripped):
            raise ValueError("module_name must be lower_snake_case")
        return v_stripped

    @model_validator(mode="after")
    def validate_payload_activity(self) -> "ModularPayloadBase":
        if not self.is_active and len(self.payload) > 0:
            raise ValueError("empty payload required when inactive")
        return self
