#!/usr/bin/env python3

from datetime import datetime

from atproto_client import Client
from pydantic import Field
from pydantic_settings import BaseSettings


class TestSettings(BaseSettings):
    test_handle: str = Field(..., description="Test account handle")
    test_password: str = Field(..., description="Test account password")

    model_config = {"env_file": ".env", "case_sensitive": False, "extra": "ignore"}


def create_spongebob_test_post():
    settings = TestSettings()

    client = Client(base_url="https://bsky.social")
    client.login(login=settings.test_handle, password=settings.test_password)

    timestamp = datetime.now().strftime("%H:%M:%S")
    spongebob_text = f"ThIs Is A tEsT pOsT fOr CuRsOr DeBuGgInG - {timestamp}"

    print(f"Creating test post: {spongebob_text}")

    response = client.send_post(text=spongebob_text)

    print("Post created successfully!")
    print(f"Post URI: {response.uri}")
    print(f"Post CID: {response.cid}")
    print(f"Timestamp: {timestamp}")

    return response


if __name__ == "__main__":
    create_spongebob_test_post()
